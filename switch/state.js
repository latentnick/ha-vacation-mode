import fs from "node:fs";

export function restoreState(file) {
  try {
    const saved = JSON.parse(fs.readFileSync(file, "utf8"));
    return saved?.on === true;
  } catch (error) {
    if (error.code === "ENOENT" || error instanceof SyntaxError) return false;
    throw error; // Do not overwrite existing state when it cannot be read.
  }
}
