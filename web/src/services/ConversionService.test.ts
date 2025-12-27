import { describe, expect, it } from "vitest";
import { normalizeErrorMessage } from "./ConversionService";

describe("normalizeErrorMessage", () => {
  it("usa mensagem JSON quando disponível", () => {
    const message = normalizeErrorMessage(
      400,
      "Bad Request",
      JSON.stringify({ detail: "Arquivo inválido" }),
    );
    expect(message).toBe("Arquivo inválido");
  });

  it("ignora HTML e mostra fallback amigável", () => {
    const message = normalizeErrorMessage(
      500,
      "Internal Server Error",
      "<!DOCTYPE html><html><body>500</body></html>",
    );
    expect(message).toContain("erro interno");
  });

  it("retorna corpo em texto simples quando não é HTML", () => {
    const message = normalizeErrorMessage(
      429,
      "Too Many Requests",
      "Limite excedido",
    );
    expect(message).toBe("Limite excedido");
  });
});
