declare module 'jpeg-js' {
  export interface Decoded {
    width: number;
    height: number;
    data: Uint8Array;
  }
  export function decode(
    data: Uint8Array | Buffer,
    opts?: { useTArray?: boolean; formatAsRGBA?: boolean },
  ): Decoded;
  const _default: { decode: typeof decode };
  export default _default;
}
