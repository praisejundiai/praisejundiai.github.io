# Escala · Renascer Praise Jundiaí

App de escala do ministério de louvor: os ministros confirmam presença, pedem troca para alguém da mesma função e marcam as datas em que não podem servir. O líder monta a escala, acompanha as confirmações e cobra pelo WhatsApp.

- **Ministros:** https://praisejundiai.github.io
- **Líder:** https://praisejundiai.github.io/#lider

## Como funciona

- Página única (`index.html`), publicada pelo GitHub Pages.
- Dados no Supabase. A chave no código é a *publishable key*, feita para ficar no site; o acesso é controlado pelas regras do banco (`sql/1-estrutura.sql`).
- Ministros não leem as tabelas: só usam as funções `ministro_*`, com o código pessoal de cada um.
- Os dados da equipe (nomes e telefones) **não ficam neste repositório**.
