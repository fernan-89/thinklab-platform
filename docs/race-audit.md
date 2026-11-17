# Auditoria de corridas (ACTION-PLAN 0.5), 2026-11-17

Escopo: os adaptadores MongoDB de saída dos 36 serviços (`infrastructure/adapter/out/persistence`) e os casos de uso que os chamam. Três padrões procurados, os do plano:

1. ordenação por relógio tirado antes da escrita;
2. "olhar e depois escrever" sem apoio do banco (ler, validar no domínio, gravar só por `_id`);
3. leitura limitada a "os mais novos" usada para achar "os mais antigos".

Método: inventário por busca nos adaptadores (todas as escritas e todos os `limit`) e leitura dos casos de uso dos suspeitos. **Não foi rodada nenhuma corrida ao vivo**; os achados abaixo são de leitura de código e cada um precisa do teste que falha no código antigo antes de ser corrigido.

## Resultado por padrão

### 3. Leitura limitada a "os mais novos": nenhum achado
Os `limit` dos adaptadores (`backup`, `dr`, `capacity`, `license`, `cloud-cost`, `ipam`, `procurement`, `patch`, `cloud-inventory`, `health-monitoring`, `ledger`) são de listagens pedidas por quem chama, com teto (`MAX_LIMIT`), e as telas e promessas que **julgam** passam os filtros ao banco (o `cloud-inventory` documenta isso no próprio contrato do repositório: o limite vale para o que foi pedido, nunca antes de filtrar).

### 1. Relógio antes da escrita: nenhum achado nos adaptadores lidos
Os registros novos movem "último valor" só para frente com guarda de tempo (`capacity`, `license`, `cloud-cost`, `backup`, `dr`: filtro `newer`/`older` na própria atualização). `Instant.now()` aparece dentro do adaptador, no mesmo `Updates` da escrita. Limite desta passada: não li a lógica de cada caso de uso até o fim.

### 2. Ler, validar, gravar sem guarda: **12 serviços**
Os serviços da primeira geração gravam a transição de estado por `Filters.eq("_id", id)`, sem exigir o estado lido. Dois pedidos simultâneos passam pela validação do domínio ao mesmo tempo, os dois gravam, vale o último, e a trilha de auditoria fica com as duas entradas contra um só estado final. Os registros novos já usam a guarda (ADR-033 do vendor registry: `save(entity, expectedStatus, auditEntry)`).

| Serviço | Escritas por `_id` sem guarda de estado | Consequência pior |
|---|---|---|
| `it-discovery` | `updateStatus`, `updatePromotion` | **Alta.** Dois `promote` ao mesmo tempo criam dois ativos no registro de ativos; o segundo `promotedAssetId` sobrescreve o primeiro e um ativo fica órfão |
| `it-change-management` | `updateStatus`, `updateAssessment`, `updateRouting`, `updateScheduling`, `updateCompletion`, `updateRollback`, `updateClose` | Alta. Duas transições (implementar e reverter, por exemplo) ao mesmo tempo; o estado final não é o de nenhuma delas |
| `it-hardware-maintenance` | `updateStatus`, `updateTriage`, `updateRma`, `updateCompleteRepair`, `updatePass` | Média/alta. Mesma forma, ordem de serviço |
| `workflow-approval` | `updateStatus` (a decisão `addDecision` já é guardada) | Média. Estado final da solicitação pode divergir das decisões |
| `subscription-billing` | `updateStatus`, `updatePlan` | Média. Ativar e suspender ao mesmo tempo; a mudança de plano concorre com o estado |
| `it-asset-registry` | `updateStatus`, `updateAssignment`, `updateBasicInfo` | Média. Desativar ao mesmo tempo que entra em manutenção |
| `it-topology-graph` | `Node.updateStatus`, `Edge.updateStatus` | Baixa/média |
| `site-reference-data-directory` | `updateStatus`, `updateRackStatus` | Baixa/média |
| `identity-federation` | `IdentityProvider.updateStatus`/`updateSettings` | Média (muda como as pessoas entram) |
| `notification-dispatch` | `updateStatus(id, status, attempts, lastError)` | Baixa. Contagem de tentativas pode regredir |
| `ci-type-catalog` | `update` por `_id` | Baixa |
| `consumable-inventory` | uma escrita por `_id` (as de saldo já são guardadas) | Baixa |

`it-service-request`, `it-problem-management`, `it-incident-management`, `it-knowledge-base`, `it-alerting` e `it-external-ticketing` já têm guarda; `party-reference-data-directory` filtra por outro campo e ficou para a segunda passada.

## Correção proposta

Para as transições sem efeito fora do serviço: trocar `updateX(id, ...)` por `saveX(entity, expectedStatus, auditEntry)` com o filtro `{_id, organisationId, status: expected}` e `matchedCount == 0` virando 409 (`ERR-<DOM>-00409`), exatamente como a ADR-033 do vendor registry. Um serviço por PR, cada um com o teste de dois pedidos simultâneos que falha no código antigo (o padrão de `VendorPersistenceIT`) e um smoke curto de vinte pedidos ao mesmo tempo, como o do vendor.

**`it-discovery` pede decisão antes**, porque a promoção tem efeito fora do serviço (cria o ativo). Guardar só a gravação final faria o perdedor levar 409 depois de já ter criado um ativo. Opções:
1. reservar antes de agir: transição guardada `UNDER_REVIEW -> PROMOTING`, criar o ativo, fechar em `PROMOTED`; quem perde a reserva recebe 409 sem criar nada, e um `PROMOTING` esquecido é recuperável pela leitura (novo estado, ADR própria);
2. tornar a criação do ativo idempotente pela chave externa do item e guardar a gravação final: o perdedor recebe o mesmo ativo, sem estado novo, mas depende de o registro de ativos recusar ou devolver o ativo existente para a mesma chave (a verificar).

Ordem sugerida: `it-discovery` (após a decisão), `it-change-management`, `workflow-approval`, `subscription-billing`, `it-hardware-maintenance`, `it-asset-registry`, depois o resto.

## Resultado (2026-11-17)

Os doze serviços foram corrigidos, um PR por serviço, cada um com um teste de corrida contra MongoDB real que falhou no código antigo, ADR própria, README e o portão de 100% de linhas e ramos. Padrão: escrita guardada por `{_id, status esperado}`; sem correspondência, 404 se o documento não existe e 409 (`ERR-<DOM>-00409`) se existe e mudou. A decisão do `it-discovery` foi a opção 1 (reservar antes, estado `PROMOTING`).

| Serviço | PR | Nota |
|---|---|---|
| `it-discovery` | it-discovery#3 (fundido) | reserva `PROMOTING`, retomada de reserva abandonada após 5 minutos |
| `it-change-management` | it-change-management#5 | lease de 2 minutos antes de chamar workflow-approval e operation-window; roteamento e agendamento não criam duas vezes |
| `workflow-approval` | workflow-approval#6 | a corrida cancelar x última aprovação não reproduziu no código antigo; o teste fica como proteção |
| `subscription-billing` | subscription-billing#3 | `updatePlan` guarda o plano lido; mudanças sequenciais legítimas formam uma cadeia sem quebra |
| `it-hardware-maintenance` | it-hardware-maintenance#4 | |
| `it-asset-registry` | it-asset-registry#10 | o tratador de eventos de ordem de serviço continua fail-open (ADR-026) |
| `it-topology-graph` | it-topology-graph#3 | |
| `identity-federation` | identity-federation#3 | |
| `ci-type-catalog` | ci-type-catalog#3 | |
| `consumable-inventory` | consumable-inventory#3 | |
| `site-reference-data-directory` | site-reference-data-directory#3 | |
| `notification-dispatch` | notification-dispatch#9 | guarda por status e tentativas (retry vale de `SENDING`); despacho reserva antes de chamar o canal |

O CI de todos os PRs estava verde na última leitura (o de `notification-dispatch` ainda rodando).

### Aceito e deixado como está (documentado nas ADRs dos serviços)

- `updateRackStatus` do serviço de sites: sem efeito fora do serviço e sem trilha; fica para a segunda passada.
- Edição de `ApprovalPolicy` e `updateDetails` do estoque de consumíveis: último a gravar vale, sem transição de estado.
- Reativação de aresta no `it-topology-graph`: a checagem de nó existente continua fora da escrita.
- `it-change-management`: rota e agendamento validam antes de tomar o lease; há uma janela curta entre a validação e o lease, coberta pela escrita guardada.
- `party-reference-data-directory` (filtra por outro campo) segue para a segunda passada.
