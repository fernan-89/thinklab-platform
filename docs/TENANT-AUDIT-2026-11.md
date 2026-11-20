# Auditoria de tenant nas rotas por id (ACTION-PLAN 0.8-c)

Data: 2026-11-17. **Só relatório**: nenhum serviço foi alterado. Vem do achado do workflow-approval (ADR-037): uma rota que acha o objeto só pelo `id` deixa quem souber um UUID ler ou alterar dado de outro tenant.

## Método e limite

Passada estática sobre os 35 serviços `micronaut-*-service`: (1) portas de repositório com `findById(UUID id)` sem organização; (2) chamadas a `repository.findById(x)` de um argumento nos casos de uso; (3) rotas `{id}` do controller **sem** o cabeçalho `X-Tenant-Id`. É uma varredura de texto: **não prova** que há vazamento (um caso de uso pode carregar pelo id e comparar a organização depois, como o service-request faz) e **não prova** o contrário. A prova é um teste entre tenants (abaixo).

## Resultado

| Grupo | Serviços (rotas por id sem tenant / rotas por id) | Leitura |
|---|---|---|
| **A. Lacuna provável** (dado do tenant, rota só com o id) | asset-registry (8/8), change-management (13/13), discovery (6/6), hardware-maintenance (18/18; só `X-Executor` e `X-Role`), operation-window (8/8), site-reference-data-directory (10/10), ci-type-catalog (5/5), topology-graph (9/10), notification-dispatch (6/6) | Os serviços mais antigos. Amostra lida: `GET /{id}/retrieve` do asset-registry e do discovery recebe só o `id`. |
| **B. A olhar caso a caso** | hash-token-registry (6/6, ids soberanos, provavelmente global por desenho), party-authentication (5/7), party-reference-data-directory (13/13, a organização é a raiz), subscription-billing (5/12, planos são globais, assinaturas são do tenant) | Pode ser por desenho; cada um precisa de uma decisão. |
| **C. Porta sem tenant, rotas com tenant** | compliance-audit-ledger, consumable-inventory, identity-federation, service-request (2 chamadas) | O tenant chega ao serviço; falta ler o caso de uso para saber se compara depois de carregar. |
| **D. Com escopo** | alerting, backup, capacity, cloud-cost, cloud-inventory, dr-registry, external-ticketing (2 chamadas a verificar), health-monitoring (1 a verificar), incident, install-kit, ipam, knowledge-base, license, patch, problem, procurement, vendor, workflow-approval (corrigido em 2026-11-14), gateway | Os serviços feitos depois do padrão de tenant em toda rota. |

Padrão: **os serviços das primeiras jornadas (ativos, mudanças, descoberta, manutenção, janelas, sites, catálogo de tipos, topologia, notificações) não filtram por tenant nas rotas por id**; os feitos depois, sim.

## Situação em 2026-11-18

**Grupo A fechado.** Os nove serviços (asset-registry, change-management, discovery, hardware-maintenance, operation-window, site-reference-data-directory, ci-type-catalog, topology-graph, notification-dispatch) exigem `X-Tenant-Id` em toda rota por id; o objeto de outro tenant é um 404; o repositório não tem mais `findById` sem organização. Cada um tem ADR, teste de outro tenant, pasta de isolamento no Postman e 100% de cobertura.

**Prova:** o probe `scripts/e2e/tenant-probe.sh` roda no e2e e mostra os nove como `ok` (`own=200`, `retrieve=404`, `audit-log/retrieve=404` onde há). A lista `LEAKY` está vazia: um vazamento novo em qualquer um deles reprova o job.

**O que o fechamento exigiu além dos serviços:** os smokes (`.sh` e `.ps1`) e o `seed-demo.ps1` passaram a mandar o tenant nas chamadas por id; a suite Postman do asset-registry, que ativa um tipo no ci-type-catalog, também.

### Grupos B e C, lidos caso a caso (2026-11-20)

Lidos os casos de uso e as rotas dos dez serviços; a varredura de texto do relatório original errou em parte (marcou portas que já eram com escopo). Decisões do dono do produto e o que ficou:

| Serviço | Leitura | Decisão |
|---|---|---|
| **party-reference-data-directory** | A organização é o tenant. Qualquer tenant lia, editava, suspendia e cancelava outra organização pelo UUID, via unidades e contatos, e **listava todas** (`GET /retrieve`). **Vazamento real.** | Só a própria organização: o `X-Tenant-Id` precisa ser o `{id}`; a lista devolve só a do chamador; `initiate` continua sem tenant. Sem papel de plataforma por ora. PR party-reference-data-directory#9 (ADR-016). |
| **party-authentication** | Usuários têm organização; 5 rotas por id (retrieve, update, activate, suspend, deactivate) só recebiam o id. **Vazamento real.** Credencial e revogação de sessão já comparavam o tenant depois de carregar. | Escopar tudo: uma busca `findById(id, organisationId)`, usada também pela sessão federada e pelo refresh (a organização vem do registro do refresh token). PR party-authentication#9 (ADR-023). |
| compliance-audit-ledger, consumable-inventory, identity-federation, subscription-billing (só assinaturas) | Já isolavam (carregam pelo id e comparam a organização no caso de uso), mas a porta ainda tinha `findById(id)` sem organização. | Apertar a porta, sem mudança de comportamento. PRs ledger#4, consumable#4, federation#4, billing#4. |
| service-request, external-ticketing, health-monitoring | Falso positivo da varredura: as portas já são `findById(id, organisationId)`. | Nada a fazer; contam como grupo D. |
| hash-token-registry | Ids soberanos e hashes sem `organisationId` no modelo: global por desenho. | Aceito, sem mudança. |
| subscription-billing (planos) | O catálogo de planos é compartilhado por todos os tenants. | Aceito, sem mudança. |

O probe ganhou duas linhas (organização e usuário); começam em `LEAKY` e saem quando os PRs entram.

**Aberto:** a política CAB/ECAB por tenant do change-management (ACTION-PLAN 0.8-d). O `seed-demo.ps1` ainda chama o subscription-billing (planos, globais) sem tenant, o que é coerente com a decisão acima.

## Como fechar (proposta, a decidir)

1. **Prova primeiro:** um script de sondagem que, para cada serviço do grupo A, cria um objeto como o tenant X e tenta ler, alterar e cancelar como o tenant Y pelo gateway. Resultado esperado hoje: 200 onde deveria ser 404. Dá a lista exata e vira o teste de regressão.
2. **Um PR por serviço**, na ordem de gravidade (mudanças e ativos primeiro, por serem os que mais guardam): cabeçalho `X-Tenant-Id` obrigatório nas rotas por id, `findById(id, organisationId)` no repositório (o sem tenant deixa de existir), teste de outro tenant dando 404, Postman com o cabeçalho, 100% de cobertura.
3. **Chamadores primeiro** (padrão do ADR-037): quem chama essas rotas de outro serviço (o discovery chama o asset-registry, o change-management chama o operation-window, o hardware-maintenance chama o asset-registry) passa a mandar o tenant antes de o serviço chamado passar a exigir. O web e o gateway já mandam o tenant em toda chamada.
4. Grupos B e C: decidir caso a caso (global por desenho, ou escopo), depois tratar como o grupo A.

Custo estimado: 9 serviços do grupo A, um PR cada (P a M), mais os chamadores.
