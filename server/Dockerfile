# maliang 后端 —— Node 原生 TS 执行（类型剥离），无需编译。
# muvee 构建上下文 = 仓库根；本 Dockerfile 路径 server/Dockerfile。
FROM node:23-slim

WORKDIR /app
RUN corepack enable

# 先装依赖（利用缓存）。运行时只需 prod 依赖（fastify/pngjs/jpeg-js）；
# typescript/@types 仅类型检查用，运行时 node 原生剥离类型，不需要。
COPY server/package.json server/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile --prod

COPY server/ ./

# muvee：HTTP 必须在 8080；持久化只有 /workspace 存活 → 数据目录指向 /workspace/data
ENV PORT=8080
ENV MALIANG_DATA_DIR=/workspace/data
EXPOSE 8080

CMD ["node", "src/index.ts"]
