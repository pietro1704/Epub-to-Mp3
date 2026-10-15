import { describe, expect, it, vi } from "vitest";
vi.mock("../wasm/converter_wasm", () => ({ default: vi.fn(), ConversionSession: vi.fn(), inspect_epub: vi.fn() }));
import { verifyBrowserFaber } from "./BrowserConversionClient";
function storedFile(size: number) {
  const file = new File(["fixture"], "model", { lastModified: 42 });
  Object.defineProperty(file, "size", { value: size });
  Object.defineProperty(file, "arrayBuffer", { value: async () => new ArrayBuffer(1) });
  return file;
}
const bytes = (hex: string) => Uint8Array.from(hex.match(/../g) ?? [], value => parseInt(value, 16)).buffer;
describe("browser model integrity", () => {
  it("removes corrupt model artifacts before inference", async () => {
    const directory = { getFileHandle: vi.fn(async () => ({ getFile: async () => storedFile(63_201_294) })), removeEntry: vi.fn(async () => undefined) };
    await expect(verifyBrowserFaber(directory, async () => new ArrayBuffer(32))).rejects.toThrow("checksum validation failed");
    expect(directory.removeEntry).toHaveBeenCalledWith("pt_BR-faber-medium.onnx");
    expect(directory.removeEntry).toHaveBeenCalledWith("pt_BR-faber-medium.onnx.json");
  });
  it("verifies both catalog checksums and avoids repeatedly hashing unchanged weights", async () => {
    const directory = { getFileHandle: vi.fn(async (name: string) => ({ getFile: async () => storedFile(name.endsWith(".json") ? 4_855 : 63_201_294) })), removeEntry: vi.fn(async () => undefined) };
    const digest = vi.fn().mockResolvedValueOnce(bytes("858555e3a064209c57088fe6bd70c4c3dc54d03eaa00c45d5ecaf43a33f95aa7")).mockResolvedValueOnce(bytes("7e694de195ae3fc36dd732c445eb04fb49b649854893cb5506b978f0d50a1d6f"));
    await verifyBrowserFaber(directory, digest);
    await verifyBrowserFaber(directory, digest);
    expect(digest).toHaveBeenCalledTimes(2);
    expect(directory.removeEntry).not.toHaveBeenCalled();
  });
});
