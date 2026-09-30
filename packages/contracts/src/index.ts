import { z } from "zod";

/** Loopback health payload. Source failures are reported separately. */
export const HealthSchema = z
  .object({
    status: z.literal("ok"),
    schemaVersion: z.literal(1),
    mode: z.enum(["passive", "live", "fixture"]),
    readOnly: z.literal(true),
  })
  .strict();

export type Health = z.infer<typeof HealthSchema>;

export function parseHealth(input: unknown): Health {
  return HealthSchema.parse(input);
}
