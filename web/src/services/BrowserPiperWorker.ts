import { TtsSession } from "@mintplex-labs/piper-tts-web";
import initWasm, { encode_wav_mp3 } from "../wasm/converter_wasm";

const port = self as unknown as {
  onmessage: ((event: MessageEvent<{ text: string }>) => void) | null;
  postMessage(message: unknown, transfer?: Transferable[]): void;
};
port.onmessage = async ({ data }) => {
  try {
    const session = await TtsSession.create({
      voiceId: "pt_BR-faber-medium",
      wasmPaths: { onnxWasm: "/tts/", piperData: "/tts/piper_phonemize.data", piperWasm: "/tts/piper_phonemize.wasm" },
    });
    const wav = await (await session.predict(data.text)).arrayBuffer();
    await initWasm();
    const encoded = encode_wav_mp3(new Uint8Array(wav)).slice().buffer as ArrayBuffer;
    port.postMessage({ wav: encoded }, [encoded]);
  } catch (error) { port.postMessage({ error: String(error) }); }
};
