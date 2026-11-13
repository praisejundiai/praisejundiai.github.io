-- =====================================================================
-- ESCALA RENASCER PRAISE JUNDIAÍ · estrutura do banco (Supabase)
-- Rode este arquivo PRIMEIRO no Supabase: SQL Editor → New query → colar → Run
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- tabelas ----------
create table if not exists public.pessoas (
  id            text primary key,
  nome          text not null,
  whats         text not null default '',
  funcoes       text[] not null default '{}',
  indisp        date[] not null default '{}',
  obs           text,
  token         uuid not null default gen_random_uuid() unique,
  falhas        int not null default 0,
  bloqueado_ate timestamptz,
  criado        timestamptz not null default now()
);

create table if not exists public.eventos (
  id    text primary key,
  nome  text not null,
  data  date not null,
  hora  text not null
);

create table if not exists public.vagas (
  id            text primary key,
  evento_id     text not null references public.eventos(id) on delete cascade,
  funcao        text not null,
  pessoa_id     text references public.pessoas(id) on delete set null,
  status        text not null default 'pendente',
  motivo        text not null default '',
  troca         boolean not null default false,
  pedido_para   text references public.pessoas(id) on delete set null,
  recusaram     text[] not null default '{}',
  status_antes  text,
  grupo         text,
  substituiu    text,
  respondido_em timestamptz
);
create index if not exists vagas_evento on public.vagas(evento_id);
create index if not exists vagas_pessoa on public.vagas(pessoa_id);

create table if not exists public.equipes (
  slot        text primary key,
  linhas      jsonb not null default '[]',
  todas_vozes boolean not null default false
);

create table if not exists public.lideres (
  email text primary key
);

-- ---------- segurança: tudo trancado por padrão ----------
alter table public.pessoas enable row level security;
alter table public.eventos enable row level security;
alter table public.vagas   enable row level security;
alter table public.equipes enable row level security;
alter table public.lideres enable row level security;

revoke all on public.pessoas, public.eventos, public.vagas, public.equipes, public.lideres from anon, authenticated;

-- quem é líder
create or replace function public.eh_lider() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.lideres
                 where lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));
$$;

-- o líder (logado) pode tudo nas tabelas da escala
grant select, insert, update, delete on public.pessoas, public.eventos, public.vagas, public.equipes to authenticated;
grant select on public.lideres to authenticated;

drop policy if exists lider_pessoas on public.pessoas;
create policy lider_pessoas on public.pessoas for all to authenticated using (public.eh_lider()) with check (public.eh_lider());
drop policy if exists lider_eventos on public.eventos;
create policy lider_eventos on public.eventos for all to authenticated using (public.eh_lider()) with check (public.eh_lider());
drop policy if exists lider_vagas on public.vagas;
create policy lider_vagas on public.vagas for all to authenticated using (public.eh_lider()) with check (public.eh_lider());
drop policy if exists lider_equipes on public.equipes;
create policy lider_equipes on public.equipes for all to authenticated using (public.eh_lider()) with check (public.eh_lider());
drop policy if exists lider_ve_a_si on public.lideres;
create policy lider_ve_a_si on public.lideres for select to authenticated
  using (lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));

-- =====================================================================
-- FUNÇÕES DOS MINISTROS (sem login: usam o código pessoal = token)
-- Os ministros nunca leem as tabelas direto; só por estas funções.
-- =====================================================================

create or replace function public.hoje_br() returns date
language sql stable as $$ select (now() at time zone 'America/Sao_Paulo')::date $$;

create or replace function public.norm(t text) returns text
language sql immutable as $$
  select translate(lower(coalesce(t, '')), 'áàâãäéèêëíìîïóòôõöúùûüç', 'aaaaaeeeeiiiiooooouuuuc')
$$;

-- próximo culto (para a tela de apresentação, sem login)
create or replace function public.proximo_culto() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('data', data, 'hora', hora, 'nome', nome)
  from public.eventos
  where (data + hora::time) >= (now() at time zone 'America/Sao_Paulo')
  order by data, hora limit 1
$$;

-- busca pelo nome: devolve só nome e se precisa dos 4 últimos dígitos
create or replace function public.ministro_buscar(q text)
returns table (id text, nome text, funcoes text[], precisa_codigo boolean)
language sql stable security definer set search_path = public as $$
  select p.id, p.nome, p.funcoes, (p.whats <> '')
  from public.pessoas p
  where length(public.norm(q)) >= 2
    and ( public.norm(p.nome) like public.norm(q) || '%'
          or exists (select 1 from unnest(string_to_array(public.norm(p.nome), ' ')) w
                     where w like public.norm(q) || '%'
                        or regexp_replace(w, '\.$', '') like public.norm(q) || '%') )
  order by p.nome
  limit 10
$$;

-- entrar: confere os 4 últimos dígitos do WhatsApp e devolve o código pessoal
create or replace function public.ministro_entrar(p_id text, p_final text) returns uuid
language plpgsql security definer set search_path = public as $$
declare p public.pessoas;
begin
  select * into p from public.pessoas where id = p_id;
  if not found then return null; end if;
  if p.bloqueado_ate is not null and p.bloqueado_ate > now() then
    raise exception 'Muitas tentativas. Tente de novo em alguns minutos.';
  end if;
  if p.whats = '' or right(regexp_replace(p.whats, '\D', '', 'g'), 4) = regexp_replace(coalesce(p_final, ''), '\D', '', 'g') then
    update public.pessoas set falhas = 0, bloqueado_ate = null where id = p_id;
    return p.token;
  end if;
  update public.pessoas
     set falhas = falhas + 1,
         bloqueado_ate = case when falhas + 1 >= 5 then now() + interval '15 minutes' else null end
   where id = p_id;
  return null;
end $$;

create or replace function public.pessoa_do_token(p_token uuid) returns public.pessoas
language plpgsql stable security definer set search_path = public as $$
declare p public.pessoas;
begin
  select * into p from public.pessoas where token = p_token;
  if not found then raise exception 'Código pessoal inválido. Entre de novo pelo seu nome.'; end if;
  return p;
end $$;

-- tudo o que a tela do ministro precisa (cultos de hoje em diante)
create or replace function public.ministro_dados(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare eu public.pessoas;
begin
  eu := public.pessoa_do_token(p_token);
  return jsonb_build_object(
    'eu', eu.id,
    'pessoas', coalesce((select jsonb_agg(jsonb_build_object(
        'id', p.id, 'nome', p.nome, 'whats', p.whats, 'funcoes', p.funcoes,
        'indisp', p.indisp, 'obs', p.obs) order by p.nome) from public.pessoas p), '[]'),
    'eventos', coalesce((select jsonb_agg(jsonb_build_object(
        'id', e.id, 'nome', e.nome, 'data', e.data, 'hora', e.hora,
        'vagas', coalesce((select jsonb_agg(jsonb_build_object(
            'id', v.id, 'funcao', v.funcao, 'pessoaId', v.pessoa_id, 'status', v.status,
            'motivo', v.motivo, 'troca', v.troca, 'pedidoPara', v.pedido_para,
            'recusaram', v.recusaram, 'statusAntes', v.status_antes, 'grupo', v.grupo,
            'substituiu', v.substituiu)) from public.vagas v where v.evento_id = e.id), '[]')
      ) order by e.data, e.hora) from public.eventos e where e.data >= public.hoje_br()), '[]')
  );
end $$;

-- a pessoa pode servir nessa vaga? (função, data livre, sem outra escala no mesmo horário)
create or replace function public.pode_servir(p_pessoa text, p_vaga text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.vagas v
    join public.eventos e on e.id = v.evento_id
    join public.pessoas p on p.id = p_pessoa
    where v.id = p_vaga
      and v.funcao = any (p.funcoes)
      and not (e.data = any (p.indisp))
      and not exists (select 1 from public.vagas v2 join public.eventos e2 on e2.id = v2.evento_id
                      where v2.pessoa_id = p_pessoa and v2.id <> v.id and v2.status <> 'recusado'
                        and e2.data = e.data and e2.hora = e.hora)
  )
$$;

-- ações do ministro
create or replace function public.ministro_acao(p_token uuid, p_acao text, p_vaga text default null, p_extra jsonb default '{}')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  eu public.pessoas;
  v  public.vagas;
  e  public.eventos;
  d  date;
  para text;
  v_motivo text := coalesce(p_extra ->> 'motivo', '');
begin
  eu := public.pessoa_do_token(p_token);

  if p_acao in ('indisp_add', 'indisp_rm') then
    d := (p_extra ->> 'data')::date;
    if p_acao = 'indisp_add' then
      if d < public.hoje_br() then raise exception 'Escolha uma data a partir de hoje.'; end if;
      update public.pessoas set indisp = array(select distinct x from unnest(indisp || d) x order by x) where id = eu.id;
    else
      update public.pessoas set indisp = array_remove(indisp, d) where id = eu.id;
    end if;
    return jsonb_build_object('ok', true);
  end if;

  select * into v from public.vagas where id = p_vaga for update;
  if not found then raise exception 'Essa escala não existe mais. Atualize a tela.'; end if;
  select * into e from public.eventos where id = v.evento_id;
  if e.data < public.hoje_br() then raise exception 'Esse culto já passou.'; end if;

  if p_acao = 'confirmar' then
    if v.pessoa_id is distinct from eu.id or v.status <> 'pendente' then raise exception 'Essa escala já foi respondida.'; end if;
    update public.vagas set status = 'confirmado', respondido_em = now() where id = v.id;

  elsif p_acao = 'pedir_troca' then
    para := p_extra ->> 'para';
    if v.pessoa_id is distinct from eu.id or v.grupo is not null or v.status not in ('pendente', 'confirmado', 'trocando') then
      raise exception 'Não é possível pedir troca dessa escala.'; end if;
    if para is null or para = eu.id or para = any (v.recusaram) or not public.pode_servir(para, v.id) then
      raise exception 'Essa pessoa não pode substituir você nesse horário.'; end if;
    update public.vagas set
      status_antes = case when status <> 'trocando' then status else status_antes end,
      status = 'trocando', pedido_para = para, motivo = v_motivo, respondido_em = now()
    where id = v.id;

  elsif p_acao = 'recusar_todos' then
    if v.pessoa_id is distinct from eu.id or v.grupo is distinct from 'todos' then raise exception 'Ação inválida.'; end if;
    update public.vagas set status = 'recusado', motivo = v_motivo, troca = false, respondido_em = now() where id = v.id;

  elsif p_acao = 'avisar_lider' then
    if v.pessoa_id is distinct from eu.id then raise exception 'Ação inválida.'; end if;
    update public.vagas set status = 'recusado', troca = true, pedido_para = null,
      motivo = case when v_motivo <> '' then v_motivo else vagas.motivo end, respondido_em = now()
    where id = v.id;

  elsif p_acao = 'cancelar_troca' then
    if v.pessoa_id is distinct from eu.id or v.status <> 'trocando' then raise exception 'Ação inválida.'; end if;
    update public.vagas set status = coalesce(status_antes, 'confirmado'), pedido_para = null where id = v.id;

  elsif p_acao = 'aceitar_troca' then
    if v.pedido_para is distinct from eu.id or v.status <> 'trocando' then raise exception 'Esse pedido não está mais aberto.'; end if;
    if not public.pode_servir(eu.id, v.id) then raise exception 'Você já está escalado nesse horário.'; end if;
    update public.vagas set substituiu = pessoa_id, pessoa_id = eu.id, status = 'confirmado', pedido_para = null,
      motivo = '', recusaram = '{}', status_antes = null, respondido_em = now()
    where id = v.id;

  elsif p_acao = 'negar_troca' then
    if v.pedido_para is distinct from eu.id then raise exception 'Esse pedido não está mais aberto.'; end if;
    update public.vagas set recusaram = array_append(recusaram, eu.id), pedido_para = null where id = v.id;

  elsif p_acao = 'assumir' then
    if v.status not in ('recusado', 'aberta') or v.grupo is not null then raise exception 'Essa vaga não está mais aberta.'; end if;
    if not public.pode_servir(eu.id, v.id) then raise exception 'Você não pode assumir essa vaga.'; end if;
    update public.vagas set substituiu = pessoa_id, pessoa_id = eu.id, status = 'confirmado', motivo = '', troca = false,
      pedido_para = null, respondido_em = now()
    where id = v.id;

  else
    raise exception 'Ação desconhecida: %', p_acao;
  end if;

  return jsonb_build_object('ok', true);
end $$;

-- quem pode chamar o quê
revoke all on function public.ministro_buscar(text), public.ministro_entrar(text, text), public.ministro_dados(uuid),
  public.ministro_acao(uuid, text, text, jsonb), public.proximo_culto(), public.pode_servir(text, text),
  public.pessoa_do_token(uuid), public.eh_lider(), public.hoje_br(), public.norm(text) from public, anon, authenticated;
grant execute on function public.ministro_buscar(text), public.ministro_entrar(text, text), public.ministro_dados(uuid),
  public.ministro_acao(uuid, text, text, jsonb), public.proximo_culto() to anon, authenticated;
grant execute on function public.eh_lider() to authenticated;
grant execute on function public.hoje_br(), public.norm(text) to anon, authenticated;
