import { describe, expect, it } from "vitest";
import { __buildFormData } from "../services/ConversionService";

// jsdom FormData lets us inspect values via get()
describe("ConversionService buildFormData", () => {
  it("never appends file when uploadId is provided", async () => {
    const file = new File(["conteudo"], "livro.epub", {
      type: "application/epub+zip",
    });

    const formData: FormData = __buildFormData({
      file,
      uploadId: "upload-123",
      engine: "edge",
      footnoteMode: "inline",
    });

    expect(formData.get("upload_id")).toBe("upload-123");
    expect(formData.get("file")).toBeNull();
  });
});
