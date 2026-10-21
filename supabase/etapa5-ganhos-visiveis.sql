-- Guria Dourada · Etapa 5: a colaboradora vê os próprios ganhos por padrão
-- (o dono ainda pode esconder de alguma em Cadastros → Equipe → Acesso)
begin;
alter table public.equipe alter column ver_comissao set default true;
update public.equipe set ver_comissao = true where papel = 'funcionaria';
commit;
