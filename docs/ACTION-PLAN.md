# ThinkLab — plano de ações (2026-10-20)

Base: reavaliação do que foi feito, do que falta e das duas inspirações do projeto (Homelable e Netdata). O desenho (hexagonal, só registrar, julgar na leitura, escritas guardadas e atômicas) se sustentou; o que muda é **parar de copiar e consolidar antes de crescer**.

**Tamanhos:** P = menos de um dia · M = alguns dias · G = uma semana ou mais. **Quem:** *Você* = ação sua · *Eu* = ação minha · *Decisão* = precisa de resposta sua.

**Definição de pronto de qualquer item:** testes com 100% de linhas e ramos; prova ao vivo (smoke ou Postman); para correção de defeito, um teste que **falha no código antigo**; ADR ou README atualizado; guia e blueprint atualizados; um PR por passo, com a ordem de merge dita no PR.

---

## Fase 0 — Estabilizar (antes de qualquer coisa nova)

| # | Ação | Quem | Tam. | Pronto quando |
|---|---|---|---|---|
| 0.1 | Mergear o platform #29 (smoke de alerting sem corrida) | Você | P | e2e da master verde |
| 0.2 | Abrir Recovery, Cloud inventory e Procurement num navegador real, com a stack no ar, e anotar o que estranhar | Você | P | lista de ajustes enviada |
| 0.3 | ~~Rodar os `.ps1` num Windows real~~ — **dispensado** (smokes só em bash, ver 1.4). O `start-local-stack.ps1` continua sendo o único script de subida local sem Docker | — | — | — |
| 0.4 | Remedir a memória das edições (Enterprise tem 38 serviços agora) | Eu | P | tabela do README atualizada |
| 0.5 | **Auditoria de corridas:** procurar nos adaptadores ordenação por relógio tirado antes da escrita, "olhar e depois escrever" sem apoio do banco e leituras limitadas a "os mais novos" usadas para achar "os mais antigos" | Eu | M | achados listados; cada um corrigido com teste que falha no código antigo |
| 0.6 | **e2e determinístico:** listar os smokes que dependem de tempo (`sleep`, agendadores, relógio) e trocá-los por "avaliar e esperar o estado"; meta de 5 execuções seguidas verdes na master | Eu | M | 5 verdes seguidas |
| 0.7 | Documentos: o guia e o blueprint deixam de ser diários; viram mapas que apontam para ADRs e READMEs de cada serviço | Eu | M | guia com menos de 1/3 do tamanho, sem perda de ADR |

## Fase 1 — Refatorar (o que mais reduz custo dali em diante)

**1.1 Contrato único de promessas** (maior retorno)
- Cada registro expõe `GET /<domínio>/v1/promises/retrieve?changedWithinDays=&verdict=&limit=` com: id, nome, veredito (`KEPT`, `BROKEN`, `NOT_JUDGED`), código fixo, status e quando mudou. Nenhum texto livre.
- O alerting passa a ter uma fonte = uma entrada de configuração (nome, URL, classe padrão). Sem cliente nem mapeamento por registro.
- Migração **estrangulada**, um registro por PR (P cada): backup, patch, capacidade, fornecedores, licenças, DR, inventário, compras. As fontes antigas continuam funcionando até o último migrar; só então saem os adaptadores específicos.
- **Pronto quando:** registrar uma fonte nova de alerta não exige uma linha de código no alerting; o smoke de promessas passa sem mudança; a regra "ler também o que se recuperou" (`changedWithinDays`) vale para todas de uma vez.
- Tam.: G no total (ADR + contrato no kit M; alerting genérico M; 8 migrações P).

**1.2 Extrair o boilerplate para o kit**
- Hoje há 10 cópias dos mesmos 5 arquivos (`GlobalExceptionHandler`, `ValidationExceptionHandler`, `HashServiceAdapter`, `BusinessException`, `ClockConfig`) e cada registro é um fork de cerca de 2.300 linhas + 1.800 de teste.
- Mover para o `micronaut-thinklab-service-kit` (com 100% de cobertura lá), atualizar o gerador de serviços, migrar os serviços um por PR (mecânico). Tam.: G.
- **Pronto quando:** um registro novo nasce do gerador com só o domínio, e uma correção transversal é feita num lugar só.

**1.3 Tela genérica de promessas e de registro no web** (usa o contrato de 1.1)
- Uma tela de "o que está quebrado" para todos os registros, e telas de registro guiadas por configuração onde são só lista e detalhe. Tam.: M.

**1.4 Uma linguagem de smoke: bash** — *decidido (2026-10-20).* Os smokes novos passam a existir **só em bash**; os `.ps1` existentes ficam como estão (sem manutenção nova) e saem do CI e do repositório quando você quiser, em um PR à parte. Isso reduz à metade o custo de cada item novo. O passe no Windows (0.3) deixa de ser pré-requisito.

## Fase 2 — Lições das inspirações ainda não construídas

**Homelable** (já feitos: coletores de descoberta, topologia com raio de impacto, saúde ao vivo, edição Homelab enxuta, Traefik e `install.sh`).

| # | Ação | Tam. |
|---|---|---|
| 2.1 | Auditar o que o web já tem de visão de rede/topologia e o que falta | P |
| 2.2 | **Canvas de rack** (porta a porta) e **planta baixa**, sobre o site-reference-data-directory (salas e racks já existem) | G |
| 2.3 | **Documento por ativo, gerado dos fatos** + biblioteca de runbooks e incidentes ligados ao item (`[[device:nas-01]]`) na base de conhecimento | G |
| 2.4 | **Visão pública somente leitura**, protegida por chave, para stakeholders | M |
| 2.5 | Coletores prontos como ferramentas que reportam: Proxmox e varredura de rede (nmap) | M cada |

**Netdata** (já feitos: histerese, pacote inicial, classificação, conector, edição Homelab).

| # | Ação | Tam. |
|---|---|---|
| 2.6 | Atraso e repetição do aviso (subida, volta, enquanto crítico) | M |
| 2.7 | Silenciamento temporário em tempo de execução, com motivo de lista fixa e prazo | M |
| 2.8 | Classe e componente nas telas e nas suítes Postman de alertas (o serviço já sabe) | P |

## Fase 3 — Produto

Ordem pelas dependências: **anexos** (3.1) → **portal do usuário final** (3.2) → **mobile e etiqueta QR** (3.3). Em paralelo: **on-call e escalonamento + calendário/SLA** (3.4), **reporting** (3.5), **hub de integrações** (3.6). Depois: **vulnerabilidades** (3.7) e **políticas e riscos** (3.8).
Cada um precisa de 3 a 4 perguntas de desenho suas antes de começar (como fizemos para DR, inventário e compras). Pendentes também: **faixas de valor na aprovação** e **orçamento por centro de custo** (compras).

## Fase 4 — Jornada 16 (só depois do contrato de 1.1)

- **Servidor MCP:** com o contrato uniforme ele expõe todos os registros de uma vez (buscar, explicar impacto, rascunhar mudança). G.
- **CLI e provider Terraform:** gerados a partir do mesmo contrato e das OpenAPI. G.
- **Instaladores** (Docker, LXC, bare metal): a base já existe (`install.sh`, edições). M.

## Fase 5 — Endurecer para uso real

Segurança ligada por padrão; implantação em Kubernetes (Helm); observabilidade (métricas e rastros com painéis); teste de carga (hoje só se mediu memória ociosa); backup e restauração da própria plataforma; plano de migração de dados e de índices entre versões. G no total.

---

## Ordem e porquê

1. **Fase 0** primeiro: sem e2e confiável e sem as telas vistas por gente, tudo que vem depois é construído sobre areia.
2. **Fase 1 antes da Jornada 16 e do produto novo:** MCP, Terraform, CLI e a tela de promessas dependem de um contrato uniforme; cada registro novo hoje custa 5 lugares.
3. **Fases 2 e 3** intercaladas: uma lição das inspirações, um item de produto.
4. **Fase 5** começa em paralelo com a 3 (segurança por padrão não deve esperar).

## Decisões que preciso de você

1. ~~Aprovar a Fase 1~~ — **o contrato de promessas foi aprovado (2026-10-20)**; a extração para o kit (1.2) segue pendente de aprovação própria.
2. ~~Linguagem única de smoke~~ — decidido: bash.
3. Qual da Fase 3 vem primeiro, e as perguntas de desenho de cada uma quando chegar a vez.
4. Se a auditoria de corridas (0.5) achar algo grave, corrigir antes de seguir? (a minha recomendação é sim).

## Riscos

- **Migração do contrato de promessas** mexe em 9 serviços: por isso estrangulada, um por PR, com o smoke de promessas como rede de segurança.
- **Extração para o kit** acopla todos os serviços a uma versão do kit: manter versionamento e migrar um por vez.
- **Os `.ps1` existentes** deixam de ser mantidos: se uma mudança de contrato os quebrar, só o bash é corrigido.
