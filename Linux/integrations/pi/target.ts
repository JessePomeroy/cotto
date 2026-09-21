export interface EditorSnapshot {
  instance: string;
  revision: number;
  text: string;
  line: number;
  col: number;
}

export interface InputTarget {
  snapshot(): EditorSnapshot | undefined;
  apply(expected: EditorSnapshot, text: string): boolean;
}

export function sameEditor(a: EditorSnapshot | undefined, b: EditorSnapshot): boolean {
  return (
    !!a &&
    a.instance === b.instance &&
    a.revision === b.revision &&
    a.text === b.text &&
    a.line === b.line &&
    a.col === b.col
  );
}
