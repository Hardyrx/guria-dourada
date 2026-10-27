-- Guria Dourada · Etapa 8: equipe agenda direto, busca cliente, bloqueia horário e vê a comissão de cada atendimento
-- Rode no SQL Editor do Supabase. Pode rodar mais de uma vez.

begin;

-- 1) Painel da colaboradora: percentual de comissão dela e dos serviços, e a comissão exata de cada atendimento pago
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
                 'foto', dados->'foto', 'tel', dados->'tel', 'comServ', dados->'comServ', 'comProd', dados->'comProd')
               from public.registros where tipo = 'profs' and id = v_prof),
    'email', v_email,
    'ver_comissao', coalesce(v_ver, false),
    'salao', (select jsonb_build_object('nome', dados->'nome', 'abre', dados->'abre', 'fecha', dados->'fecha',
                 'intervalo', dados->'intervalo', 'fechado', coalesce(dados->'fechado', '[]'::jsonb))
              from public.registros where tipo = 'config' limit 1),
    'servicos', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', dados->'nome',
                 'preco', dados->'preco', 'dur', dados->'dur', 'com', dados->'com') order by dados->>'nome')
               from public.registros where tipo = 'servicos'), '[]'),
    'agenda', coalesce((select jsonb_agg(jsonb_build_object(
                 'id', a.id, 'data', a.dados->'data', 'hora', a.dados->'hora', 'dur', a.dados->'dur',
                 'status', a.dados->'status', 'servico', s.dados->'nome', 'preco', s.dados->'preco',
                 'cliente', c.dados->'nome', 'tel', c.dados->'tel',
                 'pag', v.dados->'pag', 'total', v.dados->'total',
                 'serv', a.dados->'serv', 'obs', a.dados->'obs',
                 'minha_com', case when coalesce(v_ver, false) and v.dados is not null then
                   (select sum((cm->>'valor')::numeric) from jsonb_array_elements(coalesce(v.dados->'coms', '[]'::jsonb)) cm where cm->>'prof' = v_prof) end)
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
-- 2) Buscar cliente já cadastrada por nome ou telefone (equipe e admin). Devolve no máximo 8.
create or replace function public.buscar_clientes(p_q text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  de  constant text := 'áàâãäéèêëíìîïóòôõöúùûüçñ';
  pra constant text := 'aaaaaeeeeiiiiooooouuuucn';
  q text := translate(lower(trim(replace(replace(coalesce(p_q, ''), '%', ''), '_', ''))), de, pra);
  d text := regexp_replace(coalesce(p_q, ''), '\D', '', 'g');
begin
  if public.meu_prof() is null and not public.eh_admin() then raise exception 'Sem permissão.'; end if;
  if length(q) < 2 then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', t.id, 'nome', t.nome, 'tel', t.tel) order by t.nome)
    from (select id, dados->>'nome' as nome, dados->>'tel' as tel
          from public.registros
          where tipo = 'clientes'
            and (translate(lower(coalesce(dados->>'nome', '')), de, pra) like '%' || q || '%'
                 or (length(d) >= 4 and regexp_replace(coalesce(dados->>'tel', ''), '\D', '', 'g') like '%' || d || '%'))
          order by dados->>'nome'
          limit 8) t), '[]'::jsonb);
end;
$$;

-- 3) A profissional agenda direto pela área da equipe (já fica confirmado, na agenda dela)
create or replace function public.agendar_pela_equipe(
  p_cli text, p_nome text, p_tel text, p_data text, p_hora text, p_servs text[]) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_prof  text := public.meu_prof();
  v_agora timestamp := now() at time zone 'America/Sao_Paulo';
  v_hoje  text := to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM-DD');
  v_tel   text := regexp_replace(coalesce(p_tel, ''), '\D', '', 'g');
  v_cfg jsonb; v_abre int; v_fecha int; v_ini int; v_dur int; v_min int; n int;
  v_cli text; v_cnome text; v_ctel text; v_id text; v_primeiro text; s record;
begin
  if v_prof is null then raise exception 'Sem permissão.'; end if;
  if coalesce(p_data, '') !~ '^\d{4}-\d{2}-\d{2}$' or coalesce(p_hora, '') !~ '^\d{2}:\d{2}$' then raise exception 'Escolha dia e horário.'; end if;
  if p_data < v_hoje or p_data::date > v_hoje::date + 60 then raise exception 'Data fora do período da agenda.'; end if;
  if coalesce(array_length(p_servs, 1), 0) not between 1 and 6 then raise exception 'Escolha de 1 a 6 serviços.'; end if;

  perform pg_advisory_xact_lock(hashtext('agenda:' || p_data));

  select dados into v_cfg from public.registros where tipo = 'config' limit 1;
  if jsonb_typeof(v_cfg->'fechado') = 'array'
     and (v_cfg->'fechado') @> to_jsonb(extract(dow from p_data::date)::int) then
    raise exception 'O salão não abre neste dia.'; end if;
  v_abre := public.hm_min(v_cfg->>'abre'); v_fecha := public.hm_min(v_cfg->>'fecha'); v_ini := public.hm_min(p_hora);

  select count(*), sum(coalesce(nullif(dados->>'dur', '')::int, 60)) into n, v_dur
  from public.registros where tipo = 'servicos' and id = any (p_servs);
  if n <> array_length(p_servs, 1) then raise exception 'Serviço não encontrado. Atualize a página.'; end if;
  if v_abre is null or v_ini < v_abre or v_ini + v_dur > v_fecha then raise exception 'Horário fora do funcionamento do salão.'; end if;
  if p_data = v_hoje and v_ini <= extract(hour from v_agora) * 60 + extract(minute from v_agora) then raise exception 'Esse horário já passou.'; end if;

  if exists (
    select 1 from public.registros b
    where b.tipo = 'ags' and b.dados->>'prof' = v_prof and b.dados->>'data' = p_data
      and coalesce(b.dados->>'status', '') not in ('cancelado', 'recusado')
      and v_ini < public.hm_min(b.dados->>'hora') + coalesce(nullif(b.dados->>'dur', '')::int, 60)
      and public.hm_min(b.dados->>'hora') < v_ini + v_dur
  ) then raise exception 'Você já tem atendimento ou bloqueio nesse horário. Escolha outro.'; end if;

  -- cliente: a escolhida na busca, ou nova (reaproveita se o telefone já existe)
  if coalesce(p_cli, '') <> '' then
    select id, dados->>'nome', dados->>'tel' into v_cli, v_cnome, v_ctel from public.registros where tipo = 'clientes' and id = p_cli;
    if v_cli is null then raise exception 'Cliente não encontrada. Busque de novo.'; end if;
  else
    if length(trim(coalesce(p_nome, ''))) not between 2 and 80 then raise exception 'Digite o nome da cliente.'; end if;
    if length(v_tel) not between 10 and 13 then raise exception 'Digite um WhatsApp válido para a cliente.'; end if;
    select id, dados->>'nome', dados->>'tel' into v_cli, v_cnome, v_ctel from public.registros
    where tipo = 'clientes' and regexp_replace(coalesce(dados->>'tel', ''), '\D', '', 'g') = v_tel limit 1;
    if v_cli is null then
      v_cli := substr(md5(random()::text || clock_timestamp()::text), 1, 7);
      v_cnome := trim(p_nome); v_ctel := p_tel;
      insert into public.registros (tipo, id, dados) values ('clientes', v_cli,
        jsonb_build_object('id', v_cli, 'nome', v_cnome, 'tel', v_ctel, 'niver', '', 'obs', ''));
    end if;
  end if;

  v_min := v_ini;
  for s in
    select r.id, coalesce(nullif(r.dados->>'dur', '')::int, 60) as dur
    from unnest(p_servs) with ordinality u(sid, ord)
    join public.registros r on r.tipo = 'servicos' and r.id = u.sid
    order by u.ord
  loop
    v_id := substr(md5(random()::text || clock_timestamp()::text), 1, 7);
    v_primeiro := coalesce(v_primeiro, v_id);
    insert into public.registros (tipo, id, dados) values ('ags', v_id, jsonb_build_object(
      'id', v_id, 'data', p_data,
      'hora', lpad((v_min / 60)::text, 2, '0') || ':' || lpad((v_min % 60)::text, 2, '0'),
      'prof', v_prof, 'cli', v_cli, 'serv', s.id, 'dur', s.dur, 'status', 'agendado',
      'obs', 'Agendado pela profissional'));
    v_min := v_min + s.dur;
  end loop;

  return jsonb_build_object('id', v_primeiro, 'cliente', v_cnome, 'tel', v_ctel);
end;
$$;

-- 4) Bloquear um período da agenda (folga, compromisso). O site deixa de oferecer esse horário.
create or replace function public.bloquear_horario(p_data text, p_ini text, p_fim text, p_motivo text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_prof text := public.meu_prof();
  v_hoje text := to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM-DD');
  v_ini int; v_fim int; v_id text;
begin
  if v_prof is null then raise exception 'Sem permissão.'; end if;
  if coalesce(p_data, '') !~ '^\d{4}-\d{2}-\d{2}$' or coalesce(p_ini, '') !~ '^\d{2}:\d{2}$' or coalesce(p_fim, '') !~ '^\d{2}:\d{2}$' then
    raise exception 'Escolha o dia e o período.'; end if;
  if p_data < v_hoje or p_data::date > v_hoje::date + 60 then raise exception 'Data fora do período da agenda.'; end if;
  v_ini := public.hm_min(p_ini); v_fim := public.hm_min(p_fim);
  if v_fim <= v_ini then raise exception 'O fim precisa ser depois do início.'; end if;

  perform pg_advisory_xact_lock(hashtext('agenda:' || p_data));
  if exists (
    select 1 from public.registros b
    where b.tipo = 'ags' and b.dados->>'prof' = v_prof and b.dados->>'data' = p_data
      and coalesce(b.dados->>'status', '') not in ('cancelado', 'recusado')
      and v_ini < public.hm_min(b.dados->>'hora') + coalesce(nullif(b.dados->>'dur', '')::int, 60)
      and public.hm_min(b.dados->>'hora') < v_fim
  ) then raise exception 'Você tem atendimento ou bloqueio nesse período. Remarque ou desmarque antes.'; end if;

  v_id := substr(md5(random()::text || clock_timestamp()::text), 1, 7);
  insert into public.registros (tipo, id, dados) values ('ags', v_id, jsonb_build_object(
    'id', v_id, 'data', p_data, 'hora', p_ini, 'dur', v_fim - v_ini, 'prof', v_prof,
    'cli', '', 'serv', '', 'status', 'bloqueado', 'obs', left(trim(coalesce(p_motivo, '')), 120)));
  return v_id;
end;
$$;

-- 5) Desbloquear (a própria profissional ou o admin)
create or replace function public.desbloquear_horario(p_id text) returns text
language plpgsql security definer set search_path = '' as $$
declare v_prof text := public.meu_prof(); a jsonb;
begin
  if v_prof is null and not public.eh_admin() then raise exception 'Sem permissão.'; end if;
  select dados into a from public.registros where tipo = 'ags' and id = p_id for update;
  if a is null or a->>'status' is distinct from 'bloqueado' or (not public.eh_admin() and a->>'prof' is distinct from v_prof) then
    raise exception 'Bloqueio não encontrado.'; end if;
  update public.registros set dados = jsonb_set(dados, '{status}', '"cancelado"'), atualizado = now()
  where tipo = 'ags' and id = p_id;
  return 'desbloqueado';
end;
$$;

revoke all on function public.buscar_clientes(text) from public, anon;
revoke all on function public.agendar_pela_equipe(text, text, text, text, text, text[]) from public, anon;
revoke all on function public.bloquear_horario(text, text, text, text) from public, anon;
revoke all on function public.desbloquear_horario(text) from public, anon;
grant execute on function public.buscar_clientes(text) to authenticated;
grant execute on function public.agendar_pela_equipe(text, text, text, text, text, text[]) to authenticated;
grant execute on function public.bloquear_horario(text, text, text, text) to authenticated;
grant execute on function public.desbloquear_horario(text) to authenticated;

commit;
