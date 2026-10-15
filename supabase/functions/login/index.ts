// 基翔小學通（測試版）登入閘門：驗證 4 位數密碼（錯 3 次鎖 1 分鐘），通過後簽發 Supabase 登入狀態。
// 需以 verify_jwt = false 部署（登入前還沒有 JWT）。service_role 金鑰只存在於伺服器環境變數。
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function reply(obj: unknown) {
  return new Response(JSON.stringify(obj), { status: 200, headers: { ...CORS, "Content-Type": "application/json" } });
}

function anonKey(): string {
  const k = Deno.env.get("SUPABASE_ANON_KEY");
  if (k) return k;
  try { return JSON.parse(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS") ?? "{}")["default"] ?? ""; } catch { return ""; }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return reply({ status: "error", message: "method not allowed" });

  let body: { email?: unknown; pin?: unknown };
  try { body = await req.json(); } catch { return reply({ status: "denied" }); }
  const email = typeof body.email === "string" ? body.email.toLowerCase() : "";
  const pin = typeof body.pin === "string" ? body.pin : "";
  if (!/^[a-z0-9_-]{1,100}@school\.test$/.test(email) || pin.length > 64) return reply({ status: "denied" });

  const url = Deno.env.get("SUPABASE_URL")!;
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: att, error: attErr } = await admin.rpc("login_attempt", { p_email: email, p_pin: pin });
  if (attErr) return reply({ status: "error", message: "login check failed" });
  if (!att || att.status !== "ok") return reply({ status: att?.status ?? "denied", retry_after: att?.retry_after, remaining: att?.remaining });

  // 密碼正確：不寄信地產生一次性登入連結，再換成 session
  const { data: link, error: linkErr } = await admin.auth.admin.generateLink({ type: "magiclink", email });
  const tokenHash = link?.properties?.hashed_token;
  if (linkErr || !tokenHash) return reply({ status: "error", message: "session issue failed" });

  const plain = createClient(url, anonKey(), { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: ver, error: verErr } = await plain.auth.verifyOtp({ token_hash: tokenHash, type: "magiclink" });
  if (verErr || !ver.session) return reply({ status: "error", message: "session issue failed" });

  return reply({
    status: "ok",
    access_token: ver.session.access_token,
    refresh_token: ver.session.refresh_token,
  });
});
