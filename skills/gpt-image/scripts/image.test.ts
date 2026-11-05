import { describe, expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { configFromEnvironment, decodeResult, models, prepareRequest, sendRequest } from "./image";

const prompt = "A red cube on white";
const image = { image_url: "data:image/png;base64,aGVsbG8=" };
const prepare = (body = {}, features: string[] = [], operation = "generate") =>
  prepareRequest(operation, { prompt, ...body }, { features });
const encoded = (bytes: Buffer | string) => ({ data: [{ b64_json: Buffer.from(bytes).toString("base64") }] });

describe("model selection and compatibility", () => {
  test("Flare is default; Sunburst and configuration override are explicit", () => {
    expect(prepare().body.model).toBe(models.flare);
    expect(prepare({ model: models.sunburst }).body.model).toBe(models.sunburst);
    expect(prepareRequest("generate", { prompt, model: models.flare }, { model: models.sunburst }).body.model).toBe(models.sunburst);
  });
  for (const model of [...models.previous, "gpt-image-2.5"]) {
    test(`preserves legacy id ${model}`, () => {
      expect(prepare({ model }).body.model).toBe(model);
    });
  }
  test("rejects shut-down and chat models", () => {
    expect(() => prepare({ model: "gpt-image-1" })).toThrow("shut down");
    expect(() => prepare({ model: "gpt-6-astra" })).toThrow("not a chat model");
    for (const model of ["gpt-image-", "gpt-image-2.6 flare", "chatgpt-image-latest-extra", ""])
      expect(() => prepare({ model })).toThrow("Use an image model");
  });
  test("normalizes feature lists and treats blank environment overrides as unset", () => {
    const config = configFromEnvironment({ GPT_IMAGE_MODEL: "", GPT_IMAGE_PROXY_URL: "",
      GPT_IMAGE_FEATURES: " SVG , gif, ", GPT_IMAGE_MAX_FRAMES: "16" });
    expect(config).toEqual({ model: undefined, proxyURL: undefined, features: ["svg", "gif"], maxFrames: 16 });
    expect(prepareRequest("generate", { prompt, model: models.sunburst }, config).body.model).toBe(models.sunburst);
  });
  test("does not invent a dated 2.6 snapshot", () => {
    expect(Object.values(models).flat().filter((id) => /2\.6-.*2026/.test(id))).toEqual([]);
  });
});

describe("request contracts", () => {
  test("uses Images endpoints only", () => {
    expect(prepare().path).toBe("/v1/images/generations");
    expect(prepare({ images: [image] }, [], "edit").path).toBe("/v1/images/edits");
  });
  test("quality and complexity are independent, no complexity injection", () => {
    expect(prepare().body).not.toHaveProperty("complexity");
    for (const quality of ["auto", "low", "medium", "high", "xhigh", "max"])
      for (const complexity of ["low", "medium", "high"])
        expect(prepare({ quality, complexity }, ["complexity"]).body).toMatchObject({ quality, complexity });
    expect(() => prepare({ quality: "hd" })).toThrow("quality");
    expect(() => prepare({ complexity: "max" }, ["complexity"])).toThrow("complexity");
    expect(() => prepare({ complexity: "high" })).toThrow("opt-in");
  });
  test("does not apply 2.5 custom-size limits to 2.6", () => {
    expect(prepare({ size: "4000x900" }).body.size).toBe("4000x900");
    expect(() => prepare({ size: "0x1024" })).toThrow("size");
  });
  test("validates count and JPEG/WebP-only compression", () => {
    expect(prepare({ n: 10 }).body.n).toBe(10);
    for (const n of [0, 11, 1.5]) expect(() => prepare({ n })).toThrow("n must");
    expect(prepare({ output_format: "webp", output_compression: 0 }).body.output_compression).toBe(0);
    expect(() => prepare({ output_format: "png", output_compression: 80 })).toThrow("requires jpeg");
  });
  test("requires JSON edits images array and preserves references", () => {
    expect(() => prepare({}, [], "edit")).toThrow("images array");
    expect(prepare({ images: [image, { file_id: "file-1" }] }, [], "edit").body.images).toHaveLength(2);
    expect(() => prepare({ images: [image] })).toThrow("edits-only");
  });
  test("markup is an explicit edits-only feature", () => {
    expect(() => prepare({ images: [image], markup: image }, [], "edit")).toThrow("opt-in");
    const body = { images: [image], markup: { file_id: "file-overlay" } };
    expect(prepare(body, ["markup"], "edit").body.markup).toEqual(body.markup);
    expect(() => prepare({ markup: image }, ["markup"])).toThrow("edits-only");
    for (const extra of [{ mask: image }, { prompt_rewriter: false }])
      expect(() => prepare({ ...body, ...extra }, ["markup"], "edit")).toThrow("cannot be combined");
  });
  test("markup reference uses exactly one source, PNG data URLs only", () => {
    for (const markup of [{}, { image_url: image.image_url, file_id: "file-1" }, { other: "x" }, { image_url: "http://example.com/a.png" }, { image_url: "data:image/jpeg;base64,aA==" }])
      expect(() => prepare({ images: [image], markup }, ["markup"], "edit")).toThrow();
    expect(prepare({ images: [image], markup: image }, ["markup"], "edit").body.markup).toEqual(image);
    expect(() => prepare({ images: [image], markup: { image_url: "DATA:IMAGE/JPEG;BASE64,aA==" } }, ["markup"], "edit")).toThrow("transparent PNG");
    for (const image_url of ["DATA:IMAGE/PNG;BASE64,aA==", "https://example.com/overlay.png"]) {
      const markup = { image_url };
      expect(prepare({ images: [image], markup }, ["markup"], "edit").body.markup).toEqual(markup);
    }
  });
  test("rejects streaming field even when false or malformed", () => {
    for (const stream of [true, false, null, 0, ""])
      expect(() => prepare({ stream })).toThrow("omit streaming");
  });
  test("SVG needs n=1; no edits, streaming, partials, compression or rewriting", () => {
    expect(prepare({ output_format: "svg", n: 1 }, ["svg"]).body.output_format).toBe("svg");
    for (const extra of [{ n: 2 }, { stream: true }, { partial_images: 0 }, { output_compression: 80 }, { prompt_rewriter: false }])
      expect(() => prepare({ output_format: "svg", ...extra }, ["svg"])).toThrow();
    expect(() => prepare({ output_format: "svg", images: [image] }, ["svg"], "edit")).toThrow("generations-only");
    expect(() => prepare({ images: [{ image_url: "data:image/svg+xml;base64,PHN2Zy8+" }] }, [], "edit")).toThrow();
  });
  test("GIF is opt-in, defaults are left to API; disputed upper limit configurable", () => {
    expect(() => prepare({ output_format: "gif" })).toThrow("opt-in");
    expect(prepare({ output_format: "gif" }, ["gif"]).body).not.toHaveProperty("frame_count");
    for (const frame_count of [16, 64, 65])
      expect(prepare({ output_format: "gif", frame_count }, ["gif"]).body.frame_count).toBe(frame_count);
    expect(() => prepareRequest("generate", { prompt, output_format: "gif", frame_count: 17 }, { features: ["gif"], maxFrames: 16 })).toThrow("frame_count");
    expect(() => prepareRequest("generate", { prompt, output_format: "gif" }, { features: ["gif"], maxFrames: 2 })).toThrow("Default frame_count");
    expect(() => prepareRequest("generate", { prompt, output_format: "gif" }, { features: ["gif"], maxFrames: NaN })).toThrow("GPT_IMAGE_MAX_FRAMES");
    for (const frame_duration_ms of [20, 2000])
      expect(prepare({ output_format: "gif", frame_duration_ms }, ["gif"]).body.frame_duration_ms).toBe(frame_duration_ms);
    for (const extra of [{ frame_count: 1 }, { frame_duration_ms: 19 }, { frame_duration_ms: 2001 }, { stream: true }, { partial_images: 0 }, { output_compression: 20 }, { prompt_rewriter: true }])
      expect(() => prepare({ output_format: "gif", ...extra }, ["gif"])).toThrow();
    expect(() => prepare({ frame_count: 9 })).toThrow("require GIF");
    expect(() => prepare({ output_format: "gif", images: [image] }, ["gif"], "edit")).toThrow("generations-only");
  });
});

describe("result handling", () => {
  test("decodes SVG XML as UTF-8 and GIF as binary", () => {
    const svg = '<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"><text>café</text></svg>';
    expect(decodeResult(encoded(svg), "svg")[0].bytes.toString("utf8")).toBe(svg);
    expect(decodeResult(encoded("GIF89a"), "gif")[0].format).toBe("gif");
    for (const preamble of ['<!DOCTYPE svg>', '<?xml version="1.0"?><!--header--><!DOCTYPE svg>'])
      expect(decodeResult(encoded(`${preamble}<svg xmlns="http://www.w3.org/2000/svg"/>`), "svg")[0].format).toBe("svg");
    expect(decodeResult(encoded("<svg/>"), "svg")[0].format).toBe("svg");
  });
  test("recognizes old raster formats without response metadata", () => {
    for (const [bytes, format] of [
      [Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), "png"],
      [Buffer.from([255, 216, 255, 224]), "jpeg"],
      [Buffer.from("RIFF1234WEBP"), "webp"],
    ] as const)
      expect(decodeResult(encoded(bytes))[0].format).toBe(format);
  });
  test("rejects silent format downgrade, missing and malformed data", () => {
    expect(() => decodeResult(encoded("GIF89a"), "svg")).toThrow("not requested svg");
    for (const response of [{}, { data: [] }, { data: [{ url: "https://example.com" }] }, { data: [{ b64_json: "$$$" }] }, encoded("not an image")])
      expect(() => decodeResult(response)).toThrow();
    expect(() => decodeResult({ data: [null] })).toThrow("Missing or invalid b64_json");
  });
});

describe("proxy integration (isolated local contract server, not live OAuth)", () => {
  test("passes model and new parameters unchanged and decodes every result", async () => {
    let received: any;
    let path = "";
    const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: async (req) => {
      path = new URL(req.url).pathname;
      received = await req.json();
      return Response.json({ data: [encoded("GIF89a").data[0], encoded("GIF89a").data[0]] });
    } });
    try {
      const request = prepare({ model: models.sunburst, output_format: "gif", frame_count: 32, complexity: "low", quality: "max" }, ["gif", "complexity"]);
      const result = await sendRequest(request, `http://127.0.0.1:${server.port}`);
      expect(path).toBe("/v1/images/generations");
      expect(received).toEqual(request.body);
      expect(decodeResult(result, "gif")).toHaveLength(2);
    } finally { server.stop(true); }
  });
  test("reports backend model rejection without retry or substitution", async () => {
    let calls = 0;
    const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => {
      calls++;
      return Response.json({ error: { code: "unsupported_model", message: "Model not supported" } }, { status: 400 });
    } });
    try {
      await expect(sendRequest(prepare(), `http://127.0.0.1:${server.port}`)).rejects.toThrow("unsupported_model: Model not supported");
      expect(calls).toBe(1);
    } finally { server.stop(true); }
  });
  test("never sends dummy auth or source images to a remote origin", async () => {
    await expect(sendRequest(prepare(), "https://api.openai.com")).rejects.toThrow("loopback");
    await expect(sendRequest(prepare(), "http://localhost:8317/other")).rejects.toThrow("loopback");
  });
  test("refuses redirects rather than forwarding source images", async () => {
    const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () =>
      Response.redirect("https://example.com", 307) });
    try {
      await expect(sendRequest(prepare(), `http://127.0.0.1:${server.port}`)).rejects.toThrow();
    } finally { server.stop(true); }
  });
  test("reports non-JSON backend errors", async () => {
    const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () =>
      new Response("Bad gateway", { status: 502 }) });
    try {
      await expect(sendRequest(prepare(), `http://127.0.0.1:${server.port}`)).rejects.toThrow("HTTP 502: non-JSON");
    } finally { server.stop(true); }
  });
  test("CLI reads a request file, honors config and saves UTF-8 SVG", async () => {
    const dir = await mkdtemp(join(tmpdir(), "gpt-image-test-"));
    const svg = '<svg xmlns="http://www.w3.org/2000/svg"><text>café</text></svg>';
    let received: any;
    const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: async (req) => {
      received = await req.json();
      return Response.json(encoded(svg));
    } });
    try {
      const request = join(dir, "request.json");
      await Bun.write(request, JSON.stringify({ prompt, output_format: "svg" }));
      const child = Bun.spawn([process.execPath, join(import.meta.dir, "image.ts"), "generate", request, join(dir, "asset")], {
        env: { ...process.env, GPT_IMAGE_MODEL: models.sunburst, GPT_IMAGE_FEATURES: " SVG, ",
          GPT_IMAGE_PROXY_URL: `http://127.0.0.1:${server.port}`, GPT_IMAGE_MAX_FRAMES: "" },
        stdout: "pipe", stderr: "pipe",
      });
      const [stdout, stderr, code] = await Promise.all([
        new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
      ]);
      expect({ code, stderr }).toEqual({ code: 0, stderr: "" });
      const saved = JSON.parse(stdout);
      expect(received.model).toBe(models.sunburst);
      expect(saved.files).toEqual([join(dir, "asset.svg")]);
      expect(await Bun.file(saved.files[0]).text()).toBe(svg);
    } finally {
      server.stop(true);
      await rm(dir, { recursive: true, force: true });
    }
  });
});
