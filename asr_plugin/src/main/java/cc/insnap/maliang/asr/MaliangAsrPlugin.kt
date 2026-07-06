package cc.insnap.maliang.asr

import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.OnlineModelConfig
import com.k2fsa.sherpa.onnx.OnlineRecognizer
import com.k2fsa.sherpa.onnx.OnlineRecognizerConfig
import com.k2fsa.sherpa.onnx.OnlineStream
import com.k2fsa.sherpa.onnx.OnlineTransducerModelConfig
import java.util.concurrent.Executors
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot

/**
 * 端侧流式中文 ASR（sherpa-onnx Zipformer int8）。
 *
 * 模型从 APK assets 的 [MODEL_DIR] 读取（scripts/build-asr-plugin.sh 放入本模块 src/main/assets/，随 AAR 合并进 APK）。
 * 生命周期：initialize()（异步加载模型 → asr_ready）→ startSession → feedPcm(16k PCM16LE)×N
 * → stopSession（尾部静音收尾 → final_result）。所有推理都在单线程 executor 上，
 * GDScript 侧只做字节搬运，绝不阻塞主线程/音频线程。
 */
class MaliangAsrPlugin(godot: Godot) : GodotPlugin(godot) {

    companion object {
        private const val MODEL_DIR = "asr-models/sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12"
        private const val SAMPLE_RATE = 16000
    }

    private val executor = Executors.newSingleThreadExecutor()
    private var recognizer: OnlineRecognizer? = null
    private var stream: OnlineStream? = null
    private var lastPartial = ""

    override fun getPluginName() = "MaliangAsr"

    override fun getPluginSignals() = setOf(
        SignalInfo("asr_ready"),
        SignalInfo("partial_result", String::class.java),
        SignalInfo("final_result", String::class.java),
        SignalInfo("asr_error", String::class.java),
    )

    /** 异步加载模型（~秒级），完成后发 asr_ready；失败发 asr_error。幂等。 */
    @UsedByGodot
    fun initialize() {
        executor.execute {
            if (recognizer != null) {
                emitSignal("asr_ready")
                return@execute
            }
            try {
                val assets = activity!!.assets
                // 模型没打进 APK（未跑 fetch 脚本）时不要让 sherpa 原生层崩，提前报错回落服务端
                assets.open("$MODEL_DIR/tokens.txt").close()
                recognizer = OnlineRecognizer(
                    assetManager = assets,
                    config = OnlineRecognizerConfig(
                        featConfig = FeatureConfig(sampleRate = SAMPLE_RATE, featureDim = 80),
                        modelConfig = OnlineModelConfig(
                            transducer = OnlineTransducerModelConfig(
                                encoder = "$MODEL_DIR/encoder-epoch-20-avg-1-chunk-16-left-128.int8.onnx",
                                decoder = "$MODEL_DIR/decoder-epoch-20-avg-1-chunk-16-left-128.onnx",
                                joiner = "$MODEL_DIR/joiner-epoch-20-avg-1-chunk-16-left-128.int8.onnx",
                            ),
                            tokens = "$MODEL_DIR/tokens.txt",
                            numThreads = 2,
                            provider = "cpu",
                            modelType = "zipformer2",
                        ),
                        decodingMethod = "greedy_search",
                    ),
                )
                emitSignal("asr_ready")
            } catch (e: Throwable) {
                emitSignal("asr_error", "init failed: ${e.message}")
            }
        }
    }

    /** 模型已就绪则可走端侧；GDScript 据此决定端侧/服务端路由。 */
    @UsedByGodot
    fun isReady(): Boolean = recognizer != null

    @UsedByGodot
    fun startSession() {
        executor.execute {
            val rec = recognizer ?: return@execute emitSignal("asr_error", "not initialized")
            stream?.release()
            stream = rec.createStream("")
            lastPartial = ""
        }
    }

    /** 16kHz 单声道 PCM16LE 分片（与服务端 voice_chunk 同一采集源）。 */
    @UsedByGodot
    fun feedPcm(chunk: ByteArray) {
        executor.execute {
            val rec = recognizer ?: return@execute
            val s = stream ?: return@execute
            s.acceptWaveform(pcm16ToFloat(chunk), SAMPLE_RATE)
            while (rec.isReady(s)) rec.decode(s)
            val text = rec.getResult(s).text
            if (text.isNotEmpty() && text != lastPartial) {
                lastPartial = text
                emitSignal("partial_result", text)
            }
        }
    }

    /** 收尾：补 0.6s 静音吐出最后几个字，发 final_result 并释放会话。 */
    @UsedByGodot
    fun stopSession() {
        executor.execute {
            val rec = recognizer ?: return@execute emitSignal("asr_error", "not initialized")
            val s = stream ?: return@execute emitSignal("asr_error", "no active session")
            s.acceptWaveform(FloatArray(SAMPLE_RATE * 6 / 10), SAMPLE_RATE)
            while (rec.isReady(s)) rec.decode(s)
            val text = rec.getResult(s).text.trim()
            s.release()
            stream = null
            emitSignal("final_result", text)
        }
    }

    override fun onMainDestroy() {
        executor.execute {
            stream?.release()
            stream = null
            recognizer?.release()
            recognizer = null
        }
        executor.shutdown()
        super.onMainDestroy()
    }

    private fun pcm16ToFloat(bytes: ByteArray): FloatArray {
        val n = bytes.size / 2
        val out = FloatArray(n)
        for (i in 0 until n) {
            val lo = bytes[2 * i].toInt() and 0xff
            val hi = bytes[2 * i + 1].toInt()
            out[i] = ((hi shl 8) or lo).toShort().toInt() / 32768f
        }
        return out
    }
}
