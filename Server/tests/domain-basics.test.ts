import { describe, expect, test } from "bun:test";
import type { DictionaryEntry, DictationContinuation, PersonalDictionary } from "../src/api.ts";
import { applyDictionary, decodePersonalDictionary, defaultDictionary, dictionaryKey, dictionaryValidationError, dictionaryVocabularyTerms, recognitionVocabularyTerms } from "../src/domain/dictionary.ts";
import { cleanTranscript, vocabularyPrompt } from "../src/domain/cleaner.ts";
import { composeDictation, DictationContinuationMemory } from "../src/domain/composition.ts";
import { formatSpokenList } from "../src/domain/lists.ts";

const entry = (id: string, term: string, aliases: string[] = [], isPriority = false): DictionaryEntry => ({ id, term, aliases, isPriority });
const makeDictionary = (entries: DictionaryEntry[]): PersonalDictionary => ({ lists: [{ id: "personal", name: "Personal", entries }] });
const compose = (text: string, previous?: DictationContinuation) => composeDictation(formatSpokenList(text, previous?.list), previous);

describe("personal dictionary Swift parity", () => {
  test("defaults normalize only explicit preferred spellings", () => {
    expect(dictionaryVocabularyTerms(defaultDictionary)).toEqual(["MiniMax", "Codex"]);
    expect(applyDictionary(defaultDictionary, "Ask minimax and CODEX, not mini max or codecs.")).toBe("Ask MiniMax and Codex, not mini max or codecs.");
  });

  test("longest phrases and replacements do not cascade", () => {
    const dictionary = makeDictionary([
      entry("mini", "Mini"), entry("minimax", "MiniMax", ["mini max", "mini-max"]), entry("codex", "Codex", ["code x"]),
    ]);
    expect(applyDictionary(dictionary, "mini max and MINI-MAX; mini, code x and codex_plugin.")).toBe("MiniMax and MiniMax; Mini, Codex and codex_plugin.");
    expect(applyDictionary(makeDictionary([entry("alpha", "Alpha", ["first"]), entry("joined", "Joined", ["Alpha Beta"])]), "first Beta; alpha beta")).toBe("Alpha Beta; Joined");
  });

  test("canonical Unicode forms and full case folding preserve surrounding source", () => {
    const dictionary = makeDictionary([entry("cafe", "Café", ["coffee shop"]), entry("street", "Straße"), entry("sigma", "Σ")]);
    expect(applyDictionary(dictionary, "café, CAFE\u0301, COFFEE SHOP; thé\u0301. STRASSE ς")).toBe("Café, Café, Café; thé\u0301. Straße Σ");
    expect(applyDictionary(dictionary, "cafe")).toBe("cafe");
    expect(dictionaryKey("Straße")).toBe(dictionaryKey("STRASSE"));
    expect(dictionaryKey("ﬃ")).toBe("ffi");
    expect(dictionaryKey("Ꭰ")).toBe(dictionaryKey("ꭰ"));
    expect(dictionaryKey("ı")).not.toBe(dictionaryKey("I"));
  });

  test("whole graphemes, accents, connector punctuation and join controls cannot be partially replaced", () => {
    const dictionary = makeDictionary([entry("person", "Engineer", ["👩"]), entry("codex", "Codex")]);
    expect(applyDictionary(dictionary, "👩 👩🏽 👩‍💻 codex codex‿plugin codex\u200Cplugin tool\u200Dcodex")).toBe("Engineer 👩🏽 👩‍💻 Codex codex‿plugin codex\u200Cplugin tool\u200Dcodex");
    expect(applyDictionary(makeDictionary([entry("accent", "A")]), "a\u0301 A")).toBe("a\u0301 A");
  });

  test("regex and replacement metacharacters stay literal", () => {
    const dictionary = makeDictionary([entry("cpp", "C++", ["see plus plus"]), entry("money", "$Tool\\Kit", ["tool kit"]), entry("dot", "Node.js", ["node jay ess"])]);
    expect(applyDictionary(dictionary, "see plus plus, tool kit, node jay ess; c++, anode.js and c++17.")).toBe("C++, $Tool\\Kit, Node.js; C++, anode.js and c++17.");
  });

  test("priority hints stay stable and freeform terms do not install replacements", () => {
    const dictionary: PersonalDictionary = { lists: [
      { id: "first", name: "First", entries: [entry("ordinary", "ordinary", ["usual"]), entry("auth", "auth", [], true), entry("cafe", "Café")] },
      { id: "second", name: "Second", entries: [entry("qwen", "Qwen", [], true), entry("duplicate", "Café", [], true)] },
    ] };
    expect(dictionaryValidationError(dictionary)).toBeUndefined();
    expect(dictionaryVocabularyTerms(dictionary)).toEqual(["auth", "Qwen", "Café", "ordinary"]);
    expect(recognitionVocabularyTerms(dictionary, "AUTH, server\nCAFE\u0301, queue, , server")).toEqual(["auth", "Qwen", "Café", "ordinary", "server", "queue"]);
    expect(recognitionVocabularyTerms(dictionary, "auth\tmiddleware, auth  middleware, \tserver\t")).toEqual(["auth", "Qwen", "Café", "ordinary", "auth middleware", "server"]);
    expect(applyDictionary(dictionary, "usual AUTH queue")).toBe("ordinary auth queue");
  });

  test("conflicting aliases invalidate the entire pass", () => {
    for (const entries of [
      [entry("a", "Codex", ["code x"]), entry("b", "Code X")],
      [entry("a", "One", ["same"]), entry("b", "Two", ["SAME"])],
      [entry("a", "Codex"), entry("b", "CODEX")],
      [entry("a", "One", ["café"]), entry("b", "Two", ["CAFE\u0301"])],
      [entry("a", "One", ["Straße"]), entry("b", "Two", ["STRASSE"])],
    ]) {
      const dictionary = makeDictionary(entries);
      expect(dictionaryValidationError(dictionary)).toBeDefined();
      expect(applyDictionary(dictionary, "same code x")).toBe("same code x");
      expect(dictionaryVocabularyTerms(dictionary)).toEqual([]);
    }
  });

  test("strict decoding fills legacy defaults and rejects explicit nulls and wrong types", () => {
    const minimal = { lists: [{ id: "personal", name: "Personal", entries: [{ id: "codex", term: "Codex" }] }] };
    expect(decodePersonalDictionary(minimal).value).toEqual(makeDictionary([entry("codex", "Codex")]));
    expect(decodePersonalDictionary({ lists: [{ id: "empty", name: "Empty" }] }).value).toEqual({ lists: [{ id: "empty", name: "Empty", entries: [] }] });
    for (const value of [
      {}, { lists: null }, { lists: {} }, { lists: [{ name: "Personal" }] },
      { lists: [{ id: "a", name: "Personal", entries: null }] },
      { lists: [{ id: "a", name: "Personal", entries: [{ term: "Codex" }] }] },
      ...[null, 1, "true"].map((isPriority) => ({ lists: [{ id: "a", name: "A", entries: [{ id: "b", term: "Codex", isPriority }] }] })),
      ...[null, [5]].map((aliases) => ({ lists: [{ id: "a", name: "A", entries: [{ id: "b", term: "Codex", aliases }] }] })),
    ]) expect(decodePersonalDictionary(value).error).toBeDefined();
  });

  test("IDs, text, duplicate aliases and count limits are validated", () => {
    const invalid: PersonalDictionary[] = [
      { lists: [{ id: "", name: "Personal", entries: [] }] },
      { lists: [{ id: "a", name: " ", entries: [] }] },
      { lists: [{ id: "a", name: "A", entries: [] }, { id: "a", name: "B", entries: [] }] },
      makeDictionary([entry("a", "Codex"), entry("a", "MiniMax")]),
      ...[" Codex", "A\nB", "A\0B", "A\u200DB", "a".repeat(129)].map((term) => makeDictionary([entry("a", term)])),
      makeDictionary([entry("a", "Codex", ["codex"])]),
      makeDictionary([entry("a", "Codex", ["code x", "CODE X"])]),
      makeDictionary([entry("a", "Codex", Array.from({ length: 9 }, (_, index) => `alias ${index}`))]),
      makeDictionary(Array.from({ length: 501 }, (_, index) => entry(String(index), `Term${index}`))),
      { lists: Array.from({ length: 33 }, (_, index) => ({ id: String(index), name: `List${index}`, entries: [] })) },
    ];
    for (const dictionary of invalid) {
      expect(dictionaryValidationError(dictionary)).toBeDefined();
      expect(decodePersonalDictionary(dictionary).error).toBeDefined();
    }
  });

  test("UTF8 cap keeps entire source on expansion, including large single-grapheme terms", () => {
    const dictionary = makeDictionary([entry("cafe", "Café", ["cafe"])]);
    expect(applyDictionary(dictionary, "cafe cafe", 11)).toBe("Café Café");
    expect(applyDictionary(dictionary, "cafe cafe", 10)).toBe("cafe cafe");
    expect(applyDictionary(dictionary, "cafe suffix", 5)).toBe("cafe suffix");
    const expanding = makeDictionary([entry("accent", `a${"\u0301".repeat(2048)}`, ["alias"])]);
    expect(dictionaryValidationError(expanding)).toBeUndefined();
    const source = "alias ".repeat(300);
    expect(Buffer.byteLength(applyDictionary(expanding, source))).toBeGreaterThan(1_048_576);
    expect(applyDictionary(expanding, source, 24 * 1024)).toBe(source);
  });
});

describe("transcript cleaning", () => {
  test("silence markers and model tokens are removed without rewriting hesitations", () => {
    for (const marker of ["[BLANK_AUDIO]", "[no_speech]", "[SILENCE]", "(silence)", "[Music]"]) expect(cleanTranscript(` \t${marker}\n`)).toBe("");
    expect(cleanTranscript(" <|startoftranscript|>Um,  I\tmean\nthis. <|endoftext|> ")).toBe("Um, I mean\nthis.");
    expect(cleanTranscript("We heard [Music] outside.")).toBe("We heard [Music] outside.");
    expect(cleanTranscript("\u200Btext\u200B")).toBe("text");
    expect(cleanTranscript("\uFEFFtext\uFEFF")).toBe("\uFEFFtext\uFEFF");
  });

  test("vocabulary prompts are bounded by terms and graphemes", () => {
    expect(vocabularyPrompt(" auth,\nCodex, , Qwen ")).toBe("auth, Codex, Qwen");
    expect(vocabularyPrompt(Array.from({ length: 90 }, (_, index) => `t${index}`).join(",")).split(", ")).toHaveLength(80);
    const emoji = "👩🏽‍💻".repeat(1100);
    expect(vocabularyPrompt(emoji)).toBe("👩🏽‍💻".repeat(1024));
  });
});

describe("dictation composition Swift parity", () => {
  test("later holds insert new items and preserve combined preview", () => {
    const first = compose("Make a list. One, apples. Two, bananas.");
    expect(first.insertion).toBe("1. apples\n2. bananas");
    const next = compose("Next item, oranges.", first.continuation);
    expect(next.insertion).toBe("\n3. oranges");
    expect(next.preview).toBe("1. apples\n2. bananas\n3. oranges");
    const implicit = compose("More syrup.", next.continuation);
    expect(implicit.insertion).toBe("\n4. More syrup");
    expect(implicit.continuation?.list?.nextNumber).toBe(5);
  });

  test("control-only commands preserve list and never emit whitespace-only insertions", () => {
    const first = compose("Start a list. One, apples. Two, bananas.");
    const resume = compose("Continue the list.", first.continuation);
    const marker = compose("Next item.", resume.continuation);
    expect(resume.insertion).toBe("");
    expect(marker.insertion).toBe("");
    expect(marker.preview).toBe(first.preview);
    expect(marker.continuation?.list?.nextNumber).toBe(3);
    expect(compose("Oranges.", marker.continuation).insertion).toBe("\n3. Oranges");
    const end = compose("End of the list.", first.continuation);
    expect(end.insertion).toBe("");
    expect(end.continuation?.list).toBeUndefined();
    const prose = compose("Please buy these tomorrow.", end.continuation);
    expect(prose.insertion).toBe("\n\nPlease buy these tomorrow. ");
    expect(compose("End list. Please buy these tomorrow.", first.continuation)).toEqual(prose);
    expect(compose("Thank you.", prose.continuation).insertion).toBe("Thank you. ");
  });

  test("list restart retains deferred paragraphs and resets numbering/preview", () => {
    const first = compose("Start a list. Seven, syrup.");
    const next = compose("Start a new list. One, pears.", first.continuation);
    expect(next.insertion).toBe("\n\n1. pears");
    expect(next.preview).toBe("1. pears");
    const start = compose("Start a new list.", first.continuation);
    const restart = compose("Start a numbered list.", start.continuation);
    expect(compose("Pears.", restart.continuation).insertion).toBe("\n\n1. Pears");
    const combined = compose("End list. Start a new list.", first.continuation);
    expect(combined.insertion).toBe("");
    expect(compose("Oranges.", combined.continuation).insertion).toBe("\n\n1. Oranges");
  });

  test("bullet and multiline list tails produce appropriate boundaries", () => {
    const first = compose("Start a bulleted list. Bullet point, apples.");
    const second = compose("Next bullet, oranges.", first.continuation);
    expect(second.insertion).toBe("\n- oranges");
    expect(second.preview).toBe("- apples\n- oranges");
    const multiline = compose("Make a list. One, first paragraph\n\nsecond paragraph. End list.");
    expect(multiline.insertion).toBe("1. first paragraph\n\nsecond paragraph");
    expect(compose("Finished.", multiline.continuation).insertion).toBe("\n\nFinished. ");
  });

  test("plain prose appends space without accumulating prior previews", () => {
    const first = compose("I bought three oranges.");
    const next = compose("The total was $12.50.", first.continuation);
    expect(first.insertion).toBe("I bought three oranges. ");
    expect(next.insertion).toBe("The total was $12.50. ");
    expect(next.preview).toBe("The total was $12.50.");
    expect(next.continuation?.list).toBeUndefined();
    expect(compose("", first.continuation).continuation).toEqual(first.continuation);
  });

  test("continuation memory commits only confirmed delivery and expires, evicts, and clears", () => {
    const memory = new DictationContinuationMemory<string>(10, 2);
    const first = compose("Make a list. One, apples.");
    memory.remember(first.continuation, "first", 0);
    const pending = compose("Next item, oranges.", memory.continuation("first", 1));
    expect(pending.continuation?.list?.nextNumber).toBe(3);
    expect(memory.continuation("first", 2)?.list?.nextNumber).toBe(2);
    memory.remember(first.continuation, "second", 1);
    memory.remember(first.continuation, "third", 2);
    expect(memory.continuation("first", 3)).toBeUndefined();
    expect(memory.continuation("second", 10)).toBeDefined();
    expect(memory.continuation("second", 11)).toBeUndefined();
    expect(memory.continuation("third", 11)).toBeDefined();
    memory.removeAll();
    expect(memory.continuation("third", 11)).toBeUndefined();
    memory.remember(first.continuation, "first", 20);
    memory.remember(undefined, "first", 21);
    expect(memory.continuation("first", 21)).toBeUndefined();
    memory.remember(first.continuation, "first", 30);
    expect(memory.continuation("first", 29)).toBeUndefined();
  });
});
