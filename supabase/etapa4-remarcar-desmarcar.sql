-- Guria Dourada · Etapa 4: colaboradora desmarca e remarca os próprios horários
-- Rode no SQL Editor do Supabase. Pode rodar mais de uma vez.

begin;

-- 1) Painel da colaboradora passa a receber intervalo da agenda, dias fechados (para mostrar horários livres)
--    e, nos atendimentos já fechados no caixa, a forma de pagamento
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
                 and a.dados->>'data' between to_char(v_hoje - 7, 'YYYY-MM-DD') and to_char(v_hoje + 60, 'YYYY-MM-DD')
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

-- 2) Desmarcar: só horário dela, ainda não atendido, de hoje em diante
create or replace function public.desmarcar_meu_horario(p_id text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_prof text := public.meu_prof();
  v_hoje text := to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM-DD');
  a jsonb;
begin
  if v_prof is null then raise exception 'Sem permissão.'; end if;
  select dados into a from public.registros where tipo = 'ags' and id = p_id for update;
  if a is null or a->>'prof' is distinct from v_prof then raise exception 'Agendamento não encontrado.'; end if;
  if coalesce(a->>'status', '') not in ('pendente', 'agendado') then raise exception 'Esse horário não pode mais ser desmarcado.'; end if;
  if a->>'data' < v_hoje then raise exception 'Esse horário já passou.'; end if;
  update public.registros
  set dados = dados || jsonb_build_object('status', 'cancelado',
                'obs', trim(coalesce(dados->>'obs', '') || ' · Desmarcado pela profissional em ' || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'))),
      atualizado = now()
  where tipo = 'ags' and id = p_id;
  return 'cancelado';
end;
$$;

-- 3) Remarcar: novo dia e hora para um horário dela, com as mesmas regras do site
create or replace function public.remarcar_meu_horario(p_id text, p_data text, p_hora text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_prof  text := public.meu_prof();
  v_agora timestamp := now() at time zone 'America/Sao_Paulo';
  v_hoje  text := to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM-DD');
  a jsonb; v_cfg jsonb; v_ini int; v_dur int; v_abre int; v_fecha int;
begin
  if v_prof is null then raise exception 'Sem permissão.'; end if;
  if coalesce(p_data, '') !~ '^\d{4}-\d{2}-\d{2}$' or coalesce(p_hora, '') !~ '^\d{2}:\d{2}$' then raise exception 'Escolha dia e horário.'; end if;
  if p_data < v_hoje or p_data::date > v_hoje::date + 60 then raise exception 'Data fora do período da agenda.'; end if;

  perform pg_advisory_xact_lock(hashtext('agenda:' || p_data));
  select dados into a from public.registros where tipo = 'ags' and id = p_id for update;
  if a is null or a->>'prof' is distinct from v_prof then raise exception 'Agendamento não encontrado.'; end if;
  if coalesce(a->>'status', '') not in ('pendente', 'agendado') then raise exception 'Esse horário não pode mais ser remarcado.'; end if;
  if a->>'data' < v_hoje then raise exception 'Esse horário já passou.'; end if;

  select dados into v_cfg from public.registros where tipo = 'config' limit 1;
  if jsonb_typeof(v_cfg->'fechado') = 'array'
     and (v_cfg->'fechado') @> to_jsonb(extract(dow from p_data::date)::int) then
    raise exception 'O salão não abre neste dia.'; end if;
  v_abre := public.hm_min(v_cfg->>'abre'); v_fecha := public.hm_min(v_cfg->>'fecha');
  v_ini := public.hm_min(p_hora); v_dur := coalesce(nullif(a->>'dur', '')::int, 60);
  if v_abre is null or v_ini < v_abre or v_ini + v_dur > v_fecha then raise exception 'Horário fora do funcionamento do salão.'; end if;
  if p_data = v_hoje and v_ini <= extract(hour from v_agora) * 60 + extract(minute from v_agora) then raise exception 'Esse horário já passou.'; end if;

  if exists (
    select 1 from public.registros b
    where b.tipo = 'ags' and b.id <> p_id and b.dados->>'prof' = v_prof and b.dados->>'data' = p_data
      and coalesce(b.dados->>'status', '') not in ('cancelado', 'recusado')
      and v_ini < public.hm_min(b.dados->>'hora') + coalesce(nullif(b.dados->>'dur', '')::int, 60)
      and public.hm_min(b.dados->>'hora') < v_ini + v_dur
  ) then raise exception 'Você já tem atendimento nesse horário. Escolha outro.'; end if;

  update public.registros
  set dados = dados || jsonb_build_object('data', p_data, 'hora', p_hora,
                'obs', trim(coalesce(dados->>'obs', '') || ' · Remarcado pela profissional de ' || (a->>'data') || ' ' || (a->>'hora'))),
      atualizado = now()
  where tipo = 'ags' and id = p_id;
  return 'remarcado';
end;
$$;

revoke all on function public.desmarcar_meu_horario(text) from public, anon;
revoke all on function public.remarcar_meu_horario(text, text, text) from public, anon;
grant execute on function public.desmarcar_meu_horario(text) to authenticated;
grant execute on function public.remarcar_meu_horario(text, text, text) to authenticated;

commit;
