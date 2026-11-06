import { resolve } from "node:path";

// These are Images API models, not Factory chat-model entries.
export const models = {
  flare: "gpt-image-2.6-flare",
  sunburst: "gpt-image-2.6-sunburst",
  previous: [
    "gpt-image-1-mini", "gpt-image-1.5", "gpt-image-2", "gpt-image-2-2026-04-21",
    "gpt-image-2.5-flare", "gpt-image-2.5-flare-2026-09-08",
    "gpt-image-2.5-sunburst", "gpt-image-2.5-sunburst-2026-09-08",
    "chatgpt-image-latest",
  ],
};

type Request = Record<string, any>;
type Config = { model?: string; features?: string[]; maxFrames?: number };
const present = (body: Request, field: string) => body[field] !== undefined;

export function configFromEnvironment(env: Record<string, string | undefined>) {
  return {
    model: env.GPT_IMAGE_MODEL || undefined,
    features: (env.GPT_IMAGE_FEATURES || "").split(",").map((value) => value.trim().toLowerCase()).filter(Boolean),
    maxFrames: env.GPT_IMAGE_MAX_FRAMES ? Number(env.GPT_IMAGE_MAX_FRAMES) : undefined,
    proxyURL: env.GPT_IMAGE_PROXY_URL || undefined,
  };
}

function integer(value: unknown, min: number, max: number, field: string) {
  if (!Number.isInteger(value) || Number(value) < min || Number(value) > max)
    throw new Error(`${field} must be an integer from ${min} to ${max}`);
}

function imageReference(ref: any, name: string) {
  if (!ref || typeof ref !== "object" || Array.isArray(ref) ||
      Object.keys(ref).length !== 1 ||
      !["image_url", "file_id"].some((key) => typeof ref[key] === "string" && ref[key].trim()))
    throw new Error(`${name} needs exactly one of image_url or file_id`);
  if (ref.image_url && !/^https:\/\/|^data:image\/(?:png|jpeg|webp);base64,/i.test(ref.image_url))
    throw new Error(`${name}.image_url must be HTTPS or a raster base64 data URL`);
  if (ref.image_url && /\.svg(?:[?#]|$)/i.test(ref.image_url))
    throw new Error("SVG input is not supported for edits");
}

export function prepareRequest(operation: string, input: Request, config: Config = {}) {
  if (!["generate", "edit"].includes(operation)) throw new Error("Use generate or edit");
  if (!input || typeof input !== "object" || Array.isArray(input))
    throw new Error("Request must be a JSON object");
  const body: Request = { ...input, model: config.model ?? input.model ?? models.flare };
  if (typeof body.model !== "string" || !/^(?:gpt-image-[a-z0-9][a-z0-9.-]*|chatgpt-image-latest)$/.test(body.model))
    throw new Error("Use an image model, not a chat model");
  if (body.model === "gpt-image-1") throw new Error("gpt-image-1 was shut down on 2026-10-23");
  if (typeof body.prompt !== "string" || !body.prompt.trim()) throw new Error("prompt is required");
  const choose = (field: string, values: string[]) => {
    if (present(body, field) && !values.includes(body[field]))
      throw new Error(`${field} must be one of ${values.join(", ")}`);
  };
  choose("quality", ["auto", "low", "medium", "high", "xhigh", "max"]);
  choose("complexity", ["low", "medium", "high"]);
  choose("background", ["auto", "opaque", "transparent"]);
  choose("output_format", ["png", "jpeg", "webp", "svg", "gif"]);
  // 2.6's custom-resolution limits are not published. Let the API validate them.
  if (present(body, "size") && (typeof body.size !== "string" || !/^(auto|[1-9]\d*x[1-9]\d*)$/.test(body.size)))
    throw new Error("size must be auto or WIDTHxHEIGHT");
  if (present(body, "n")) integer(body.n, 1, 10, "n");
  if (present(body, "stream") || present(body, "partial_images"))
    throw new Error("This helper saves complete JSON results; omit streaming and partial_images");
  if (present(body, "response_format")) throw new Error("Omit response_format; GPT Image returns b64_json");
  if (present(body, "output_compression")) {
    integer(body.output_compression, 0, 100, "output_compression");
    if (!["jpeg", "webp"].includes(body.output_format))
      throw new Error("output_compression requires jpeg or webp");
  }
  const enable = (feature: string) => {
    if (!config.features?.includes(feature))
      throw new Error(`${feature} is opt-in: set GPT_IMAGE_FEATURES=${feature} only after checking backend support`);
  };
  if (present(body, "complexity")) enable("complexity");
  if (operation === "edit") {
    if (["svg", "gif"].includes(body.output_format)) throw new Error("SVG/GIF output is generations-only");
    if (!Array.isArray(body.images) || !body.images.length) throw new Error("edits need an images array");
    body.images.forEach((ref: any) => imageReference(ref, "images entry"));
    if (present(body, "mask")) imageReference(body.mask, "mask");
    if (present(body, "markup")) {
      enable("markup");
      if (present(body, "mask") || present(body, "prompt_rewriter"))
        throw new Error("markup cannot be combined with mask or prompt_rewriter");
      imageReference(body.markup, "markup");
      if (typeof body.markup.image_url === "string" && /^data:/i.test(body.markup.image_url) &&
          !/^data:image\/png;base64,/i.test(body.markup.image_url))
        throw new Error("markup must be a transparent PNG");
    }
  } else if (["images", "mask", "markup"].some((key) => present(body, key))) {
    throw new Error("images, mask and markup are edits-only");
  }
  if (["svg", "gif"].includes(body.output_format)) {
    enable(body.output_format);
    if (present(body, "prompt_rewriter")) throw new Error("SVG/GIF do not support prompt_rewriter");
    if (body.output_format === "svg" && (body.n ?? 1) !== 1) throw new Error("SVG requires n=1");
  }
  if (body.output_format === "gif" && config.maxFrames !== undefined) {
    integer(config.maxFrames, 2, Number.MAX_SAFE_INTEGER, "GPT_IMAGE_MAX_FRAMES");
    if (!present(body, "frame_count") && config.maxFrames < 9)
      throw new Error("Default frame_count 9 exceeds GPT_IMAGE_MAX_FRAMES; set frame_count explicitly");
  }
  if (present(body, "frame_count") || present(body, "frame_duration_ms")) {
    if (body.output_format !== "gif") throw new Error("frame fields require GIF output");
    if (present(body, "frame_count")) {
      // Guide says 64, reference says 16. No baked-in upper bound.
      const max = config.maxFrames ?? Number.MAX_SAFE_INTEGER;
      integer(max, 2, Number.MAX_SAFE_INTEGER, "GPT_IMAGE_MAX_FRAMES");
      integer(body.frame_count, 2, max, "frame_count");
    }
    if (present(body, "frame_duration_ms")) integer(body.frame_duration_ms, 20, 2000, "frame_duration_ms");
  }
  return { path: `/v1/images/${operation === "edit" ? "edits" : "generations"}`, body };
}

export function decodeResult(response: any, expectedFormat?: string) {
  if (!Array.isArray(response?.data) || !response.data.length) throw new Error("No image data returned");
  return response.data.map((item: any) => {
    if (typeof item?.b64_json !== "string" || !item.b64_json.length ||
        !/^[A-Za-z0-9+/\s]*={0,2}$/.test(item.b64_json))
      throw new Error("Missing or invalid b64_json");
    const bytes = Buffer.from(item.b64_json, "base64");
    const head = bytes.subarray(0, 512).toString("utf8").trimStart();
    const format = bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])) ? "png"
      : bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255 ? "jpeg"
      : bytes.toString("ascii", 0, 4) === "RIFF" && bytes.toString("ascii", 8, 12) === "WEBP" ? "webp"
      : /^GIF8[79]a/.test(head) ? "gif"
      : /^(?:(?:<\?xml[^>]*>|<!--[\s\S]*?-->|<!DOCTYPE[^>]*>)\s*)*<svg[\s/>]/i.test(head) ? "svg" : undefined;
    if (!format) throw new Error("Unrecognized image bytes; no output saved");
    if (expectedFormat && format !== expectedFormat)
      throw new Error(`Backend returned ${format}, not requested ${expectedFormat}; no output saved`);
    return { bytes, format };
  });
}

export async function sendRequest(request: ReturnType<typeof prepareRequest>, baseURL = "http://localhost:8317") {
  const url = new URL(baseURL);
  if (url.protocol !== "http:" || !["localhost", "127.0.0.1", "[::1]"].includes(url.hostname) ||
      url.username || url.password || url.pathname !== "/" || url.search || url.hash)
    throw new Error("GPT_IMAGE_PROXY_URL must be a loopback HTTP origin");
  const response = await fetch(new URL(request.path, url), {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: "Bearer dummy-not-used" },
    body: JSON.stringify(request.body),
    redirect: "error",
    signal: AbortSignal.timeout(180000),
  });
  const result = await response.json().catch(() => { throw new Error(`HTTP ${response.status}: non-JSON proxy response`); });
  if (!response.ok || result?.error) {
    const error = result?.error;
    throw new Error(`HTTP ${response.status} (${request.body.model}): ${error?.code || error?.type || "image_error"}: ${error?.message || "Request failed"}. ` +
      "OAuth support can lag the public Images API. Check the backend version; explicitly choose an older model or disable unsupported features. No automatic retry or model substitution.");
  }
  return result;
}

if (import.meta.main) {
  try {
    const [operation, requestFile, outputPrefix] = Bun.argv.slice(2);
    if (!requestFile || !outputPrefix) throw new Error("Usage: bun image.ts generate|edit /absolute/request.json /absolute/output-prefix");
    const config = configFromEnvironment(Bun.env);
    const request = prepareRequest(operation, await Bun.file(resolve(requestFile)).json(), config);
    const result = await sendRequest(request, config.proxyURL);
    const images = decodeResult(result, request.body.output_format);
    const files: string[] = [];
    for (const [index, image] of images.entries()) {
      const path = `${resolve(outputPrefix)}${images.length > 1 ? `-${index + 1}` : ""}.${image.format}`;
      await Bun.write(path, image.bytes, { createPath: true });
      files.push(path);
    }
    console.log(JSON.stringify({ model: request.body.model, files, size: result.size, quality: result.quality, usage: result.usage }));
  } catch (error) {
    console.error(error instanceof Error ? error.message : "Image request failed");
    process.exitCode = 1;
  }
}
