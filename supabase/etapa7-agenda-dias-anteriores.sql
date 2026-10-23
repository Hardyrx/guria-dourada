-- Guria Dourada · Etapa 7: a colaboradora vê os dias anteriores da agenda (até 2 meses para trás)
-- Rode no SQL Editor do Supabase. Pode rodar mais de uma vez.

begin;

create or replace function public.meu_painel() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_prof text := public.meu_prof();
  v_ver  boolean;
  v_email text;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  if v_prof is null then return null; end if;
  select ver_comissao, email into v_ver, v_email from public.equipe where user_id = auth.uid();
  return jsonb_build_object(
    'perfil', (select jsonb_build_object('id', id, 'nome', dados->'nome', 'cor', dados->'cor',
                 'foto', dados->'foto', 'tel', dados->'tel')
               from public.registros where tipo = 'profs' and id = v_prof),
    'email', v_email,
    'ver_comissao', coalesce(v_ver, false),
    'salao', (select jsonb_build_object('nome', dados->'nome', 'abre', dados->'abre', 'fecha', dados->'fecha',
                 'intervalo', dados->'intervalo', 'fechado', coalesce(dados->'fechado', '[]'::jsonb))
              from public.registros where tipo = 'config' limit 1),
    'servicos', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', dados->'nome',
                 'preco', dados->'preco', 'dur', dados->'dur') order by dados->>'nome')
               from public.registros where tipo = 'servicos'), '[]'),
    'agenda', coalesce((select jsonb_agg(jsonb_build_object(
                 'id', a.id, 'data', a.dados->'data', 'hora', a.dados->'hora', 'dur', a.dados->'dur',
                 'status', a.dados->'status', 'servico', s.dados->'nome', 'preco', s.dados->'preco',
                 'cliente', c.dados->'nome', 'tel', c.dados->'tel',
                 'pag', v.dados->'pag', 'total', v.dados->'total')
                 order by a.dados->>'data', a.dados->>'hora')
               from public.registros a
               left join public.registros s on s.tipo = 'servicos' and s.id = a.dados->>'serv'
               left join public.registros c on c.tipo = 'clientes' and c.id = a.dados->>'cli'
               left join lateral (select x.dados from public.registros x
                                  where x.tipo = 'vendas' and x.dados->>'agId' = a.id limit 1) v on true
               where a.tipo = 'ags' and a.dados->>'prof' = v_prof
                 and a.dados->>'data' between to_char(v_hoje - 62, 'YYYY-MM-DD') and to_char(v_hoje + 60, 'YYYY-MM-DD')
                 and coalesce(a.dados->>'status', '') not in ('cancelado', 'recusado')), '[]'),
    'comissoes', case when coalesce(v_ver, false) then coalesce((select jsonb_agg(jsonb_build_object(
                 'data', v.dados->'data', 'item', c->'item', 'base', c->'base', 'pct', c->'pct', 'valor', c->'valor')
                 order by v.dados->>'data' desc)
               from public.registros v, jsonb_array_elements(coalesce(v.dados->'coms', '[]'::jsonb)) c
               where v.tipo = 'vendas' and c->>'prof' = v_prof
                 and v.dados->>'data' >= to_char(v_hoje - 70, 'YYYY-MM-DD')), '[]') end
  );
end;
$$;

commit;
