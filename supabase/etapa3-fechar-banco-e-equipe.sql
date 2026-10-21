-- Guria Dourada · Etapa 3: fechar o banco + acesso das colaboradoras
-- Rode no SQL Editor do Supabase DEPOIS que o site novo de agendamento estiver no ar.
-- Pode rodar mais de uma vez sem problema.

begin;

-- 1) Equipe: e-mail (para o admin ver) e se a colaboradora vê a própria comissão
alter table public.equipe add column if not exists email text;
alter table public.equipe add column if not exists ver_comissao boolean not null default false;
create unique index if not exists equipe_uma_conta_por_prof on public.equipe (prof_id) where papel = 'funcionaria';

update public.equipe e set email = u.email from auth.users u where u.id = e.user_id and e.email is null;

-- 2) Fecha a tabela principal: acabou o acesso público e o "qualquer logado vê tudo".
--    Só admin lê e grava direto. Colaboradora usa as funções abaixo, que só entregam o que é dela.
drop policy if exists "publico le" on public.registros;
drop policy if exists "publico insere ags" on public.registros;
drop policy if exists "publico insere clientes" on public.registros;
drop policy if exists "equipe le" on public.registros;
drop policy if exists "equipe grava" on public.registros;
drop policy if exists "equipe altera" on public.registros;
drop policy if exists "equipe apaga" on public.registros;
drop policy if exists "admin le" on public.registros;
drop policy if exists "admin grava" on public.registros;
drop policy if exists "admin altera" on public.registros;
drop policy if exists "admin apaga" on public.registros;

create policy "admin le"     on public.registros for select to authenticated using ((select public.eh_admin()));
create policy "admin grava"  on public.registros for insert to authenticated with check ((select public.eh_admin()));
create policy "admin altera" on public.registros for update to authenticated using ((select public.eh_admin())) with check ((select public.eh_admin()));
create policy "admin apaga"  on public.registros for delete to authenticated using ((select public.eh_admin()));

-- 3) Site público passa a mostrar a foto de cada profissional
create or replace function public.agenda_publica() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'config', (select jsonb_build_object('nome', dados->'nome', 'slogan', dados->'slogan',
                 'abre', dados->'abre', 'fecha', dados->'fecha', 'intervalo', dados->'intervalo',
                 'fechado', coalesce(dados->'fechado', '[]'::jsonb))
               from public.registros where tipo = 'config' limit 1),
    'profs', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', dados->'nome',
                 'cor', dados->'cor', 'cadeira', dados->'cadeira', 'foto', dados->'foto'))
               from public.registros where tipo = 'profs' and dados->'ativo' = 'true'::jsonb), '[]'),
    'servicos', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', dados->'nome',
                 'preco', dados->'preco', 'dur', dados->'dur'))
               from public.registros where tipo = 'servicos'), '[]'),
    'ocupados', coalesce((select jsonb_agg(jsonb_build_object('data', dados->'data',
                 'hora', dados->'hora', 'dur', dados->'dur', 'prof', dados->'prof'))
               from public.registros
               where tipo = 'ags'
                 and dados->>'data' >= to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM-DD')
                 and coalesce(dados->>'status', '') not in ('cancelado', 'recusado')), '[]')
  )
$$;

-- 4) Painel da colaboradora: só a agenda dela, os clientes dos horários dela,
--    a tabela de serviços e (se o admin liberar) a própria comissão.
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
    'salao', (select jsonb_build_object('nome', dados->'nome', 'abre', dados->'abre', 'fecha', dados->'fecha')
              from public.registros where tipo = 'config' limit 1),
    'servicos', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', dados->'nome',
                 'preco', dados->'preco', 'dur', dados->'dur') order by dados->>'nome')
               from public.registros where tipo = 'servicos'), '[]'),
    'agenda', coalesce((select jsonb_agg(jsonb_build_object(
                 'id', a.id, 'data', a.dados->'data', 'hora', a.dados->'hora', 'dur', a.dados->'dur',
                 'status', a.dados->'status', 'servico', s.dados->'nome', 'preco', s.dados->'preco',
                 'cliente', c.dados->'nome', 'tel', c.dados->'tel')
                 order by a.dados->>'data', a.dados->>'hora')
               from public.registros a
               left join public.registros s on s.tipo = 'servicos' and s.id = a.dados->>'serv'
               left join public.registros c on c.tipo = 'clientes' and c.id = a.dados->>'cli'
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

-- 5) Confirmar ou recusar um pedido do site. A colaboradora só os dela; o admin, qualquer um.
--    Usa a mesma trava por dia do site: duas confirmações no mesmo segundo não geram choque.
create or replace function public.responder_pedido(p_id text, p_acao text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_prof  text := public.meu_prof();
  v_admin boolean := public.eh_admin();
  a jsonb; v_ini int; v_dur int; v_dono text;
begin
  if v_prof is null and not v_admin then raise exception 'Sem permissão.'; end if;
  if p_acao not in ('confirmar', 'recusar') then raise exception 'Ação inválida.'; end if;
  select dados into a from public.registros where tipo = 'ags' and id = p_id;
  if a is null or (not v_admin and a->>'prof' is distinct from v_prof) then raise exception 'Agendamento não encontrado.'; end if;
  perform pg_advisory_xact_lock(hashtext('agenda:' || (a->>'data')));
  select dados into a from public.registros where tipo = 'ags' and id = p_id for update;
  if a->>'status' is distinct from 'pendente' then raise exception 'Esse pedido já foi respondido.'; end if;
  v_dono := a->>'prof';

  if p_acao = 'confirmar' then
    v_ini := public.hm_min(a->>'hora');
    v_dur := coalesce(nullif(a->>'dur', '')::int, 60);
    if exists (
      select 1 from public.registros b
      where b.tipo = 'ags' and b.id <> p_id and b.dados->>'prof' = v_dono and b.dados->>'data' = a->>'data'
        and coalesce(b.dados->>'status', '') not in ('cancelado', 'recusado', 'pendente')
        and v_ini < public.hm_min(b.dados->>'hora') + coalesce(nullif(b.dados->>'dur', '')::int, 60)
        and public.hm_min(b.dados->>'hora') < v_ini + v_dur
    ) then raise exception 'Esse horário choca com outro atendimento confirmado.'; end if;
    update public.registros set dados = jsonb_set(dados, '{status}', '"agendado"'), atualizado = now()
    where tipo = 'ags' and id = p_id;
    return 'agendado';
  end if;

  update public.registros set dados = jsonb_set(dados, '{status}', '"recusado"'), atualizado = now()
  where tipo = 'ags' and id = p_id;
  return 'recusado';
end;
$$;

-- 6) Colaboradora atualiza o próprio WhatsApp e a própria foto
create or replace function public.atualizar_meu_perfil(p_tel text, p_foto text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_prof text := public.meu_prof();
begin
  if v_prof is null then raise exception 'Sem permissão.'; end if;
  if coalesce(p_foto, '') <> '' and p_foto not like
     'https://tfoazcjbnubedrwndqtc.supabase.co/storage/v1/object/public/equipe/' || v_prof || '/%' then
    raise exception 'Foto inválida.';
  end if;
  if coalesce(p_tel, '') <> '' and length(regexp_replace(p_tel, '\D', '', 'g')) not between 10 and 13 then
    raise exception 'WhatsApp inválido.';
  end if;
  -- null = não mexe; '' = apaga; texto = grava. Cada update trava a linha e lê o valor mais novo.
  if p_tel is not null then
    update public.registros
    set dados = case when p_tel = '' then dados - 'tel' else dados || jsonb_build_object('tel', p_tel) end, atualizado = now()
    where tipo = 'profs' and id = v_prof;
  end if;
  if p_foto is not null then
    update public.registros
    set dados = case when p_foto = '' then dados - 'foto' else dados || jsonb_build_object('foto', p_foto) end, atualizado = now()
    where tipo = 'profs' and id = v_prof;
  end if;
end;
$$;

-- 6b) Pedido do site agora respeita os dias em que o salão fecha (config.fechado = [0..6], 0 = domingo)
create or replace function public.solicitar_agendamento(
  p_nome text, p_tel text, p_niver text, p_data text, p_hora text, p_prof text, p_servs text[])
returns text
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

  return v_primeiro;
end;
$$;
revoke all on function public.solicitar_agendamento(text, text, text, text, text, text, text[]) from public;
grant execute on function public.solicitar_agendamento(text, text, text, text, text, text, text[]) to anon, authenticated;

-- 7) Quem pode chamar o quê
revoke all on function public.meu_painel() from public, anon;
revoke all on function public.responder_pedido(text, text) from public, anon;
revoke all on function public.atualizar_meu_perfil(text, text) from public, anon;
grant execute on function public.meu_painel() to authenticated;
grant execute on function public.responder_pedido(text, text) to authenticated;
grant execute on function public.atualizar_meu_perfil(text, text) to authenticated;
grant execute on function public.eh_admin() to authenticated;

-- 8) Fotos da equipe (Storage). Público para leitura, porque aparecem no site de agendamento.
--    Cada colaboradora só mexe na pasta dela; admin mexe em todas.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('equipe', 'equipe', true, 3145728, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = true, file_size_limit = 3145728,
  allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

drop policy if exists "equipe fotos le" on storage.objects;
drop policy if exists "equipe fotos envia" on storage.objects;
drop policy if exists "equipe fotos troca" on storage.objects;
drop policy if exists "equipe fotos apaga" on storage.objects;
create policy "equipe fotos le" on storage.objects for select to authenticated
  using (bucket_id = 'equipe');
create policy "equipe fotos envia" on storage.objects for insert to authenticated
  with check (bucket_id = 'equipe' and ((select public.eh_admin()) or (storage.foldername(name))[1] = (select public.meu_prof())));
create policy "equipe fotos troca" on storage.objects for update to authenticated
  using (bucket_id = 'equipe' and ((select public.eh_admin()) or (storage.foldername(name))[1] = (select public.meu_prof())))
  with check (bucket_id = 'equipe' and ((select public.eh_admin()) or (storage.foldername(name))[1] = (select public.meu_prof())));
create policy "equipe fotos apaga" on storage.objects for delete to authenticated
  using (bucket_id = 'equipe' and ((select public.eh_admin()) or (storage.foldername(name))[1] = (select public.meu_prof())));

commit;
