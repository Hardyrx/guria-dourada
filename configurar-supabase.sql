-- Private Suite · Guria Dourada
-- Cole tudo isso no SQL Editor do Supabase e clique em Run.

create table if not exists public.registros (
  tipo       text not null,
  id         text not null,
  dados      jsonb not null,
  atualizado timestamptz not null default now(),
  primary key (tipo, id)
);

alter table public.registros enable row level security;

-- Só quem tem login da equipe acessa. Ninguém de fora lê ou grava nada.
drop policy if exists "equipe le" on public.registros;
drop policy if exists "equipe grava" on public.registros;
drop policy if exists "equipe altera" on public.registros;
drop policy if exists "equipe apaga" on public.registros;
create policy "equipe le"     on public.registros for select to authenticated using (true);
create policy "equipe grava"  on public.registros for insert to authenticated with check (true);
create policy "equipe altera" on public.registros for update to authenticated using (true) with check (true);
create policy "equipe apaga"  on public.registros for delete to authenticated using (true);

-- Atualização em tempo real entre computador e celular
alter publication supabase_realtime add table public.registros;
