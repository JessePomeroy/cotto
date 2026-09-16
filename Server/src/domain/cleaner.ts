const graphemes = new Intl.Segmenter("en", { granularity: "grapheme" });
const trim = (text: string) => text.replace(/^[\p{White_Space}\u200B]+|[\p{White_Space}\u200B]+$/gu, "");

export function cleanTranscript(raw: string) {
  let text = trim(raw);
  const silenceMarkers = ["[BLANK_AUDIO]", "[NO_SPEECH]", "[SILENCE]", "(silence)", "[Music]", "[MUSIC]"];
  text = text.replace(/<\|[^|]*\|>/g, "").replace(/[\t ]+/g, " ");
  text = trim(text);
  if (silenceMarkers.some((marker) => text.toLowerCase() === marker.toLowerCase())) return "";
  return text;
}

export function vocabularyPrompt(vocabulary: string) {
  const prompt = vocabulary.split(/[\n,]/u).map(trim).filter(Boolean).slice(0, 80).join(", ");
  return [...graphemes.segment(prompt)].slice(0, 1024).map((segment) => segment.segment).join("");
}
