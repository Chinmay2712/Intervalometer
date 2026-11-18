// Deletes the calling user's account (App Store guideline 5.1.1(v)).
// The admin (service role) key never leaves the server.
// Gateway JWT check is off (verify_jwt = false in config.toml) because the
// caller's token is verified below with Supabase Auth.
import { createClient } from "jsr:@supabase/supabase-js@2";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ error: "Not signed in" }, 401);

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // Identify the caller from their own JWT (verified by Supabase Auth).
  const jwt = authHeader.replace(/^Bearer\s+/i, "");
  const { data: { user }, error } = await admin.auth.getUser(jwt);
  if (error || !user) return json({ error: "Not signed in" }, 401);

  // Delete with admin rights. Rows referencing auth.users cascade.
  const { error: deleteError } = await admin.auth.admin.deleteUser(user.id);
  if (deleteError) return json({ error: deleteError.message }, 500);

  return json({ deleted: true });
});
