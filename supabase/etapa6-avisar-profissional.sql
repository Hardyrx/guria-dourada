-- Guria Dourada · Etapa 6: depois de agendar, a cliente pode avisar a profissional no WhatsApp
-- O pedido passa a devolver quem vai atender (nome e WhatsApp da profissional).
-- Rode no SQL Editor do Supabase. Pode rodar mais de uma vez.

begin;

drop function if exists public.solicitar_agendamento(text, text, text, text, text, text, text[]);

create or replace function public.solicitar_agendamento(
  p_nome text, p_tel text, p_niver text, p_data text, p_hora text, p_prof text, p_servs text[])
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_agora timestamp := now() at time zone 'America/Sao_Paulo';
  v_hoje  text := to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM-DD');
  v_tel   text := regexp_replace(coalesce(p_tel, ''), '\D', '', 'g');
  v_cfg jsonb; v_abre int; v_fecha int; v_ini int; v_dur int; v_min int; n int;
  v_prof text; v_cli text; v_id text; v_primeiro text; s record;
begin
  if length(trim(coalesce(p_nome, ''))) not between 2 and 80 then raise exception 'Digite seu nome.'; end if;
  if length(v_tel) not between 10 and 13 then raise exception 'Digite um WhatsApp válido.'; end if;
  if coalesce(p_data, '') !~ '^\d{4}-\d{2}-\d{2}$' or coalesce(p_hora, '') !~ '^\d{2}:\d{2}$' then
    raise exception 'Escolha dia e horário.'; end if;
  if p_data < v_hoje or p_data::date > v_hoje::date + 60 then raise exception 'Data fora do período de agendamento.'; end if;
  if coalesce(array_length(p_servs, 1), 0) not between 1 and 6 then raise exception 'Escolha de 1 a 6 serviços.'; end if;
  if coalesce(p_niver, '') !~ '^\d{4}-\d{2}-\d{2}$' then p_niver := ''; end if;

  perform pg_advisory_xact_lock(hashtext('agenda:' || p_data));

  select dados into v_cfg from public.registros where tipo = 'config' limit 1;
  if jsonb_typeof(v_cfg->'fechado') = 'array'
     and (v_cfg->'fechado') @> to_jsonb(extract(dow from p_data::date)::int) then
    raise exception 'O salão não abre neste dia. Escolha outra data.'; end if;
  v_abre := public.hm_min(v_cfg->>'abre');
  v_fecha := public.hm_min(v_cfg->>'fecha');
  v_ini := public.hm_min(p_hora);

  select count(*), sum(coalesce(nullif(dados->>'dur', '')::int, 60)) into n, v_dur
  from public.registros where tipo = 'servicos' and id = any (p_servs);
  if n <> array_length(p_servs, 1) then raise exception 'Serviço não encontrado. Recarregue a página.'; end if;

  if v_abre is null or v_ini < v_abre or v_ini + v_dur > v_fecha then
    raise exception 'Horário fora do funcionamento do salão.'; end if;
  if p_data = v_hoje and v_ini <= extract(hour from v_agora) * 60 + extract(minute from v_agora) then
    raise exception 'Esse horário já passou.'; end if;

  v_prof := null;
  for v_id in
    select id from public.registros
    where tipo = 'profs' and dados->'ativo' = 'true'::jsonb
      and (coalesce(p_prof, '') = '' or id = p_prof)
    order by random()
  loop
    if not exists (
      select 1 from public.registros a
      where a.tipo = 'ags' and a.dados->>'prof' = v_id and a.dados->>'data' = p_data
        and coalesce(a.dados->>'status', '') not in ('cancelado', 'recusado')
        and v_ini < public.hm_min(a.dados->>'hora') + coalesce(nullif(a.dados->>'dur', '')::int, 60)
        and public.hm_min(a.dados->>'hora') < v_ini + v_dur
    ) then v_prof := v_id; exit; end if;
  end loop;
  if v_prof is null then raise exception 'Esse horário acabou de ser preenchido. Escolha outro.'; end if;

  select id into v_cli from public.registros
  where tipo = 'clientes' and regexp_replace(coalesce(dados->>'tel', ''), '\D', '', 'g') = v_tel
  limit 1;
  if v_cli is null then
    v_cli := substr(md5(random()::text || clock_timestamp()::text), 1, 7);
    insert into public.registros (tipo, id, dados) values ('clientes', v_cli,
      jsonb_build_object('id', v_cli, 'nome', trim(p_nome), 'tel', p_tel, 'niver', p_niver, 'obs', ''));
  end if;

  select count(*) into n from public.registros
  where tipo = 'ags' and dados->>'cli' = v_cli and dados->>'status' = 'pendente';
  if n >= 6 then raise exception 'Você já tem pedidos aguardando confirmação. Fale com o salão no WhatsApp.'; end if;

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
      'prof', v_prof, 'cli', v_cli, 'serv', s.id, 'dur', s.dur, 'status', 'pendente',
      'obs', 'Solicitado pelo site por ' || trim(p_nome) || ' (' || p_tel || ')'));
    v_min := v_min + s.dur;
  end loop;

  -- devolve também quem vai atender, para a cliente poder avisar a profissional no WhatsApp
  return jsonb_build_object(
    'id', v_primeiro, 'prof', v_prof,
    'prof_nome', (select dados->>'nome' from public.registros where tipo = 'profs' and id = v_prof),
    'prof_tel', (select nullif(regexp_replace(coalesce(dados->>'tel', ''), '\D', '', 'g'), '')
                 from public.registros where tipo = 'profs' and id = v_prof));
end;
$$;
revoke all on function public.solicitar_agendamento(text, text, text, text, text, text, text[]) from public;
grant execute on function public.solicitar_agendamento(text, text, text, text, text, text, text[]) to anon, authenticated;

commit;
