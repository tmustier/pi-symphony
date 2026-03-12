import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["extensions/**/*.test.ts", "extensions/**/*.spec.ts"],
    passWithNoTests: true,
    coverage: {
      reporter: ["text", "html"],
    },
  },
});
