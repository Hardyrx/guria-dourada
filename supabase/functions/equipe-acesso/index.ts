// Guria Dourada · equipe-acesso
// Só o admin chama. Cria, redefine senha, bloqueia, libera e remove o login de uma colaboradora.
// Roda no servidor do Supabase com a chave secreta (service role), que nunca vai para o navegador.
import { createClient } from "npm:@supabase/supabase-js@2.116.0";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), { status, headers: { ...cors, "Content-Type": "application/json" } });

// Senha de 10 caracteres sem letras que confundem (l, I, O, 0, 1)
function gerarSenha() {
  const a = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const limite = 256 - (256 % a.length);
  const out: string[] = [];
  while (out.length < 10) {
    for (const b of crypto.getRandomValues(new Uint8Array(16))) {
      if (b < limite && out.length < 10) out.push(a[b % a.length]);
    }
  }
  return out.join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ erro: "Método inválido." }, 405);
  try {
    const adm = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    // Quem está chamando precisa ser admin ativo
    const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: quem } = await adm.auth.getUser(token);
    if (!quem?.user) return json({ erro: "Sua sessão expirou. Entre de novo." }, 401);
    const { data: eu } = await adm.from("equipe").select("papel, ativo").eq("user_id", quem.user.id).maybeSingle();
    if (!eu || eu.papel !== "admin" || !eu.ativo) return json({ erro: "Só o admin pode gerenciar acessos." }, 403);

    const { acao, prof_id, email } = await req.json().catch(() => ({}));
    if (typeof prof_id !== "string" || !prof_id) return json({ erro: "Profissional não informada." }, 400);

    const { data: prof } = await adm.from("registros").select("id").eq("tipo", "profs").eq("id", prof_id).maybeSingle();
    if (!prof) return json({ erro: "Profissional não encontrada." }, 404);

    const { data: atual } = await adm.from("equipe").select("user_id, email, ativo")
      .eq("prof_id", prof_id).eq("papel", "funcionaria").maybeSingle();

    if (acao === "criar") {
      if (atual) return json({ erro: "Essa profissional já tem acesso." }, 409);
      const e = String(email || "").trim().toLowerCase();
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e)) return json({ erro: "Digite um e-mail válido." }, 400);
      const senha = gerarSenha();
      const { data: novo, error } = await adm.auth.admin.createUser({ email: e, password: senha, email_confirm: true });
      if (error || !novo?.user) {
        return json({ erro: /registered|exists/i.test(error?.message || "") ? "Esse e-mail já tem cadastro no sistema." : "Não foi possível criar o acesso." }, 400);
      }
      const { error: e2 } = await adm.from("equipe").insert({ user_id: novo.user.id, papel: "funcionaria", prof_id, email: e });
      if (e2) {
        await adm.auth.admin.deleteUser(novo.user.id);
        return json({ erro: "Não foi possível salvar o acesso. Tente de novo." }, 500);
      }
      return json({ ok: true, email: e, senha });
    }

    if (!atual) return json({ erro: "Essa profissional ainda não tem acesso." }, 404);

    if (acao === "senha") {
      const senha = gerarSenha();
      const { error } = await adm.auth.admin.updateUserById(atual.user_id, { password: senha });
      if (error) return json({ erro: "Não foi possível trocar a senha." }, 500);
      return json({ ok: true, email: atual.email, senha });
    }

    if (acao === "bloquear" || acao === "liberar") {
      const bloquear = acao === "bloquear";
      // Primeiro a regra do banco (corta o acesso aos dados na hora), depois o login
      const { error: e1 } = await adm.from("equipe").update({ ativo: !bloquear }).eq("user_id", atual.user_id);
      if (e1) return json({ erro: "Não foi possível alterar o acesso." }, 500);
      const { error: e2 } = await adm.auth.admin.updateUserById(atual.user_id, { ban_duration: bloquear ? "876000h" : "none" });
      if (e2) {
        if (!bloquear) await adm.from("equipe").update({ ativo: false }).eq("user_id", atual.user_id);
        return json({ erro: bloquear ? "Os dados foram bloqueados, mas o login não. Tente de novo." : "Não foi possível liberar o login." }, 500);
      }
      return json({ ok: true });
    }

    if (acao === "remover") {
      const { error } = await adm.auth.admin.deleteUser(atual.user_id); // a linha em equipe sai junto (cascade)
      if (error) return json({ erro: "Não foi possível remover o acesso." }, 500);
      return json({ ok: true });
    }

    return json({ erro: "Ação inválida." }, 400);
  } catch (_e) {
    return json({ erro: "Erro inesperado. Tente de novo." }, 500);
  }
});
