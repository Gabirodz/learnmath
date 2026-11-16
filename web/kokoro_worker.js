// The Kokoro voice (kokoro-js on Transformers.js), off the page's thread.
// Driven by learnmath_web.js. The model is fetched from Hugging Face the
// first time and kept in the browser's cache after that.
import { KokoroTTS } from 'https://cdn.jsdelivr.net/npm/kokoro-js@1.2.1/dist/kokoro.web.js';

const MODEL = 'onnx-community/Kokoro-82M-v1.0-ONNX';
let tts = null;

async function hasWebGpu() {
  try {
    return !!(await navigator.gpu?.requestAdapter());
  } catch (_) {
    return false;
  }
}

async function load(id) {
  // Bytes per file, so several files downloading at once add up to one bar.
  const files = new Map();
  const progress = (p) => {
    if (p.status !== 'progress' || !p.total) return;
    files.set(p.file, [p.loaded, p.total]);
    let loaded = 0;
    let total = 0;
    for (const [l, t] of files.values()) {
      loaded += l;
      total += t;
    }
    postMessage({ type: 'progress', id, loaded, total });
  };
  // The graphics card is many times faster; the full-precision model is the
  // one recommended for it. Without one, the small model on the processor.
  const attempts = (await hasWebGpu())
    ? [['webgpu', 'fp32'], ['wasm', 'q8']]
    : [['wasm', 'q8']];
  let lastError;
  for (const [device, dtype] of attempts) {
    try {
      files.clear();
      tts = await KokoroTTS.from_pretrained(MODEL, {
        device,
        dtype,
        progress_callback: progress,
      });
      return { device, dtype };
    } catch (e) {
      lastError = e;
    }
  }
  throw lastError;
}

self.onmessage = async (e) => {
  const m = e.data;
  try {
    if (m.type === 'load') {
      postMessage({ type: 'done', id: m.id, ...(await load(m.id)) });
    } else if (m.type === 'generate') {
      if (!tts) throw new Error('The voice is not loaded.');
      const audio = await tts.generate(m.text, {
        voice: m.voice,
        speed: m.speed,
      });
      const samples = audio.audio;
      postMessage(
        { type: 'done', id: m.id, samples, sampleRate: audio.sampling_rate },
        [samples.buffer],
      );
    }
  } catch (err) {
    postMessage({
      type: 'error',
      id: m.id,
      message: String(err?.message ?? err),
    });
  }
};
