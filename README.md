# postgresql-backup

## Backup e Recuperação de Falhas

### Objetivo

Este repositório implementa a estratégia automatizada de backup lógico e recuperação do PostgreSQL do projeto Astro. A solução atende ao requisito acadêmico de **Segurança e Integridade: definir procedimentos documentados para backup e recuperação de falhas** e não depende do computador de nenhum integrante da equipe.

O backup externo é uma camada adicional de proteção. Ele não substitui os mecanismos de continuidade, snapshots e backups administrados pela Aiven.

### Arquitetura

```text
Aiven PostgreSQL
       ↓ conexão SSL/TLS
GitHub Actions
       ↓
pg_dump --format=custom
       ↓
arquivo .dump
       ↓ API compatível com S3
Cloudflare R2 (bucket privado)
```

Na recuperação, o fluxo é invertido:

```text
Cloudflare R2
       ↓ aws s3 cp
arquivo .dump
       ↓ validação com pg_restore --list
pg_restore
       ↓ conexão SSL/TLS
PostgreSQL de teste ou destino confirmado
```

### Estratégia de proteção

- **Camada 1 — Aiven:** mecanismos de backup e recuperação fornecidos pelo provedor do PostgreSQL.
- **Camada 2 — projeto Astro:** backup lógico externo, gerado pelo GitHub Actions e armazenado no Cloudflare R2.

Separar o backup lógico do provedor do banco reduz a dependência de uma única camada e permite testar a recuperação com ferramentas nativas do PostgreSQL.

### Política de Backup e Recuperação

| Item | Regra adotada |
| --- | --- |
| Periodicidade | Diária |
| Horário | Aproximadamente 03:17 em `America/Sao_Paulo` |
| Formato | PostgreSQL custom dump (`.dump`) |
| Armazenamento | Cloudflare R2, bucket privado |
| Prefixo | `postgresql/` |
| Retenção | 7 dias por padrão, configurável |
| Automação | GitHub Actions |
| Transporte | SSL/TLS com `PGSSLMODE=require` |
| Restauração | Manual e intencional com `pg_restore` |
| Teste de recuperação | Periódico, primeiro em banco separado de produção |

O workflow [`.github/workflows/backup.yml`](.github/workflows/backup.yml) usa a expressão cron `17 6 * * *`. O agendador do GitHub Actions trabalha em UTC; portanto, `06:17 UTC` corresponde a `03:17` no fuso `America/Sao_Paulo` (UTC-3). Se a legislação de fuso horário mudar, o cron deverá ser revisado. Execuções agendadas podem sofrer pequeno atraso conforme a disponibilidade dos runners do GitHub.

### Formato e identificação dos backups

O `pg_dump` usa o formato custom do PostgreSQL (`--format=custom`). Esse formato gera um arquivo binário reconhecido pelo `pg_restore`, permite listar seu catálogo e oferece maior controle durante a restauração.

Os objetos seguem este padrão:

```text
postgresql/astro_AAAA-MM-DD_HH-MM-SS.dump
```

Exemplo:

```text
postgresql/astro_2026-09-01_03-17-00.dump
```

### Retenção

A retenção é definida pela GitHub Variable `BACKUP_RETENTION_DAYS`. Quando a variável não existe, o workflow usa **7 dias**. O valor deve ser um número inteiro maior ou igual a 1.

O script [`scripts/apply_retention.sh`](scripts/apply_retention.sh):

1. lista somente objetos sob `postgresql/`;
2. compara a data de modificação com a janela de retenção;
3. protege explicitamente o objeto criado na execução atual;
4. remove apenas objetos expirados desse prefixo;
5. registra apenas o nome de cada backup removido.

Não há exclusão genérica do bucket. A retenção evita acúmulo indefinido e consumo desnecessário do armazenamento.

### Configuração no GitHub

Cadastre estes **GitHub Secrets** no repositório:

```text
R2_ACCESS_KEY_ID
R2_SECRET_ACCESS_KEY
R2_ENDPOINT
R2_BUCKET_NAME

AIVEN_PG_HOST
AIVEN_PG_PORT
AIVEN_PG_DATABASE
AIVEN_PG_USER
AIVEN_PG_PASSWORD
```

Opcionalmente, cadastre esta **GitHub Variable**:

```text
BACKUP_RETENTION_DAYS
```

Os valores não ficam no código. No workflow, `R2_ACCESS_KEY_ID` e `R2_SECRET_ACCESS_KEY` são mapeados para `AWS_ACCESS_KEY_ID` e `AWS_SECRET_ACCESS_KEY`, e a região do AWS CLI é `auto`, conforme exigido pelo Cloudflare R2.

Para configuração local, copie [`.env.example`](.env.example) para `.env` e preencha somente no seu ambiente. O arquivo `.env` está ignorado pelo Git e nunca deve ser commitado. Não use credenciais de produção em demonstrações ou arquivos compartilhados.

### Observabilidade

Este projeto usa OpenTelemetry para enviar logs estruturados ao Grafana Cloud pelo protocolo OTLP/HTTP. O identificador fixo do serviço é `service.name=postgresql-backup`. O ambiente é determinado automaticamente como `production` no GitHub Actions e `local` nas demais execuções. Os eventos também incluem `job.name`, `worker.name`, `operation`, `status` e, quando aplicável, `service.version` e `duration_ms`.

Os logs continuam sendo escritos no console em JSON, inclusive quando a exportação não está configurada. O envio ao Grafana é habilitado somente quando as duas variáveis abaixo possuem valor:

```text
OTEL_EXPORTER_OTLP_ENDPOINT
OTEL_EXPORTER_OTLP_HEADERS
```

O exportador usa Python 3.10 ou superior e os pacotes oficiais `opentelemetry-sdk` e `opentelemetry-exporter-otlp-proto-http`, fixados em `requirements-observability.txt`. O workflow prepara um Python conhecido e só instala essas dependências quando as duas configurações do Grafana estão presentes. Sem elas, ou sem o runtime Python e os pacotes, os scripts continuam operando apenas com o log local.

O endpoint deve ser a URL base OTLP fornecida pelo Grafana Cloud, normalmente terminada em `/otlp`, sem acrescentar `/v1/logs`. O exporter oficial deriva desse valor o endpoint específico de logs, conforme o padrão OpenTelemetry. `OTEL_EXPORTER_OTLP_HEADERS` segue o formato padrão, por exemplo `Authorization=Basic%20...`; o valor real nunca deve ser colocado no repositório. Falhas temporárias de exportação geram um aviso no console, mas não interrompem o backup.

No GitHub, cadastre em **Settings → Secrets and variables → Actions** estes Repository Secrets:

```text
GRAFANA_OTLP_ENDPOINT  # valor de OTEL_EXPORTER_OTLP_ENDPOINT fornecido pelo Grafana
GRAFANA_OTLP_HEADERS   # valor de OTEL_EXPORTER_OTLP_HEADERS fornecido pelo Grafana
```

O workflow faz o mapeamento para as variáveis `OTEL_EXPORTER_OTLP_*`. Em execução local, elas são opcionais. Para testar somente o logging de console:

```bash
unset OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_HEADERS
bash scripts/otel_log.sh INFO "Teste local de observabilidade" observability-test success
```

Para validar o console e o acionamento opcional do exportador sem acessar o Grafana nem usar credenciais reais:

```bash
bash scripts/test_observability.sh
```

Para validar também o payload Protobuf, o caminho `/v1/logs`, os headers e os atributos contra um servidor HTTP local simulado:

```bash
python -m pip install -r requirements-observability.txt
python scripts/test_otel_export.py
```

Para um teste integrado, configure as duas variáveis com as credenciais do Grafana Cloud e execute o comando de teste local. No Grafana, abra **Drilldown → Logs** ou **Explore**, selecione a fonte de logs e filtre por `service_name="postgresql-backup"`. O Grafana normaliza pontos para sublinhados ao armazenar atributos OTLP no Loki. Confirme que a mensagem aparece com os metadados `severity_text`, `deployment_environment`, `worker_name`, `operation` e `status`. Em GitHub Actions, também é possível executar o workflow manualmente e procurar por `operation=backup` e `status=success`.

### Segurança

- credenciais armazenadas exclusivamente em GitHub Secrets durante a automação;
- senha do PostgreSQL fornecida por `PGPASSWORD`, nunca como argumento da linha de comando;
- conexão com PostgreSQL protegida por SSL/TLS e `PGSSLMODE=require`;
- credenciais do R2 fornecidas ao AWS CLI por variáveis de ambiente;
- bucket R2 privado, sem necessidade de acesso público;
- credenciais e políticas com o menor privilégio possível: leitura/escrita/remoção somente no bucket e prefixo necessários;
- `.env` e arquivos `.dump` ignorados pelo Git;
- retenção limitada ao prefixo `postgresql/`;
- restauração sem `DROP DATABASE`, `--clean` ou `--if-exists` por padrão;
- restauração em transação única, encerrada ao primeiro erro.

Recomenda-se usar um usuário Aiven dedicado ao backup, com apenas as permissões de leitura necessárias, e uma credencial R2 restrita ao bucket de backups. Para restauração, use um usuário separado e limitado ao banco de destino.

### Fluxo do backup

```text
GitHub Actions inicia
       ↓
valida a presença das configurações
       ↓
conecta à Aiven com SSL/TLS
       ↓
executa pg_dump em formato custom
       ↓
confirma que o arquivo existe e não está vazio
       ↓
valida o catálogo com pg_restore --list
       ↓
envia e confirma o objeto no Cloudflare R2
       ↓
remove backups expirados somente de postgresql/
       ↓
remove o arquivo temporário do runner e finaliza
```

Falhas de conexão, `pg_dump`, validação, upload ou retenção encerram o job com erro. Os logs mostram início, nome, horário, tamanho aproximado, confirmação do upload, itens removidos pela retenção e resultado final, sem imprimir senhas ou chaves.

### Execução automática

O gatilho `schedule` executa o workflow diariamente. O repositório deve permanecer habilitado para GitHub Actions, e os Secrets obrigatórios precisam estar configurados antes da primeira execução.

### Execução manual

Para gerar um backup sob demanda:

1. abra o repositório no GitHub;
2. acesse **Actions**;
3. selecione **Backup PostgreSQL**;
4. clique em **Run workflow**;
5. selecione a branch desejada e confirme.

O gatilho `workflow_dispatch` torna essa execução útil para configuração inicial e demonstrações. A execução manual cria um backup real; portanto, deve usar o ambiente e as credenciais aprovados pela equipe.

### Recuperação

Use inicialmente um banco PostgreSQL vazio e separado de produção. O script [`scripts/restore_backup.sh`](scripts/restore_backup.sh) exige uma ação manual, baixa o objeto do R2, verifica se o arquivo existe e não está vazio, executa `pg_restore --list` e só então restaura.

Dependências da máquina controlada usada na recuperação:

```text
AWS CLI
cliente PostgreSQL (pg_restore e psql)
```

Além das variáveis `R2_*`, configure as credenciais do banco de destino somente no ambiente:

```text
RESTORE_PG_HOST
RESTORE_PG_PORT
RESTORE_PG_DATABASE
RESTORE_PG_USER
RESTORE_PG_PASSWORD
CONFIRM_RESTORE_DATABASE
```

`CONFIRM_RESTORE_DATABASE` deve ser exatamente igual a `RESTORE_PG_DATABASE`. Essa confirmação reduz o risco de selecionar o banco errado. O script força `PGSSLMODE=require`, converte a senha para `PGPASSWORD` internamente e não imprime esses valores.

#### 1. Localizar um backup

Mapeie as credenciais do R2 para o AWS CLI e liste somente o prefixo do projeto:

```bash
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto

aws s3 ls \
  "s3://$R2_BUCKET_NAME/postgresql/" \
  --endpoint-url "$R2_ENDPOINT"
```

#### 2. Selecionar o banco de destino

Crie ou selecione um banco de teste vazio. Exporte as variáveis `RESTORE_PG_*` com as credenciais desse banco e confirme intencionalmente o nome:

```bash
export CONFIRM_RESTORE_DATABASE="$RESTORE_PG_DATABASE"
```

Não reutilize automaticamente as credenciais de produção. A criação do banco é uma ação administrativa separada e não é realizada pelos scripts deste repositório.

#### 3. Baixar, validar e restaurar

Execute informando a chave exibida na listagem:

```bash
bash scripts/restore_backup.sh \
  "postgresql/astro_2026-09-01_03-17-00.dump"
```

Internamente, o procedimento equivale a:

```bash
aws s3 cp \
  "s3://$R2_BUCKET_NAME/postgresql/ARQUIVO.dump" \
  "/diretorio-temporario/backup.dump" \
  --endpoint-url "$R2_ENDPOINT"

pg_restore --list "/diretorio-temporario/backup.dump"

PGSSLMODE=require pg_restore \
  --host="$RESTORE_PG_HOST" \
  --port="$RESTORE_PG_PORT" \
  --username="$RESTORE_PG_USER" \
  --dbname="$RESTORE_PG_DATABASE" \
  --no-owner \
  --no-privileges \
  --single-transaction \
  --exit-on-error \
  "/diretorio-temporario/backup.dump"
```

O script não executa `DROP DATABASE` e não usa `--clean`. Por isso, o destino deve estar vazio. Caso a equipe decida futuramente usar `--clean --if-exists`, isso deverá ser uma operação excepcional, explicitamente revisada e nunca apontada inicialmente para produção.

#### 4. Verificar a recuperação

Após o `pg_restore`, confirme:

- tabelas, views, sequências, funções e demais objetos esperados;
- permissões que precisem ser reaplicadas no ambiente de destino;
- contagens de registros em tabelas importantes;
- consultas essenciais da aplicação;
- ausência de erros no log de restauração.

### Teste real de recuperação

Gerar um `.dump` não prova, sozinho, que ele é recuperável. Todo arquivo passa pela validação inicial `pg_restore --list` antes do upload, mas a equipe também deve executar periodicamente um teste real em banco isolado — recomenda-se ao menos mensalmente e após mudanças relevantes de esquema.

O script [`scripts/test_recovery.sh`](scripts/test_recovery.sh):

1. recusa um banco de teste que já possua tabelas de aplicação;
2. chama o procedimento normal de download, validação e restauração;
3. verifica as quantidades de tabelas, views e sequências recuperadas;
4. exige uma consulta `SELECT` definida pela equipe;
5. compara o resultado com o valor esperado e falha se houver divergência.

Configure as mesmas variáveis de restauração e uma consulta de verificação que não exponha dados pessoais. Por exemplo, substitua `TABELA_IMPORTANTE` por uma tabela conhecida do projeto:

```bash
export RECOVERY_CHECK_SQL='SELECT count(*) > 0 FROM public.TABELA_IMPORTANTE'
export RECOVERY_EXPECTED_RESULT='t'

bash scripts/test_recovery.sh \
  "postgresql/astro_2026-09-01_03-17-00.dump"
```

O resultado esperado do teste é:

```text
baixar backup
       ↓
confirmar banco de teste vazio
       ↓
validar o arquivo
       ↓
executar pg_restore
       ↓
verificar estrutura e objetos
       ↓
verificar dados com consulta controlada
       ↓
confirmar recuperação sem erros
```

Registre a data, o backup testado, o ambiente isolado e o resultado no processo de evidências da equipe, sem registrar credenciais ou dados sensíveis.

### Tratamento de falhas

| Falha | Verificação e ação recomendada |
| --- | --- |
| GitHub Actions não inicia | Confirmar se Actions está habilitado, se o workflow está na branch correta e se o agendamento está ativo. Executar manualmente para diagnóstico. |
| Configuração obrigatória ausente | Conferir os nomes dos GitHub Secrets e da GitHub Variable. Nunca imprimir os valores. |
| Conexão com a Aiven falha | Verificar host, porta, usuário, permissões, disponibilidade do serviço e regras de rede. Manter `PGSSLMODE=require`. |
| `pg_dump` falha | Consultar a mensagem do job, conferir compatibilidade da versão do cliente e permissões de leitura. Nenhum arquivo com falha é enviado. |
| Backup vazio ou inválido | Descartar o arquivo, corrigir a causa e gerar um novo backup. `pg_restore --list` deve terminar com sucesso. |
| Upload para o R2 falha | Conferir endpoint, bucket, credencial e permissões no prefixo. O job termina com erro e não relata sucesso. |
| Retenção falha | Conferir permissão de listagem/exclusão e o valor de `BACKUP_RETENTION_DAYS`. A limpeza permanece restrita a `postgresql/`. |
| Restauração falha | Preservar o dump original no R2, analisar o erro, descartar/recriar somente o banco de teste e repetir após a correção. Não mudar para produção antes de um teste completo. |

Um alerta de falha no GitHub Actions deve ser investigado antes da próxima janela. Após a correção, execute o workflow manualmente e confirme o novo objeto no R2.

### Arquivos da implementação

```text
.github/workflows/backup.yml   automação diária e manual
scripts/upload_backup.sh       upload e confirmação no R2
scripts/apply_retention.sh     limpeza segura de backups expirados
scripts/restore_backup.sh      restauração manual protegida
scripts/test_recovery.sh       teste real em banco isolado
scripts/observability.sh       logging estruturado e exportacao OTLP/HTTP opcional
scripts/otel_log.sh            interface de logging para etapas do GitHub Actions
scripts/otel_export.py         exportador OTLP/HTTP Protobuf baseado no SDK oficial
scripts/test_observability.sh  teste do console e do acionamento opcional do exportador
scripts/test_otel_export.py     teste integrado local do payload Protobuf
requirements-observability.txt dependencias oficiais do OpenTelemetry
.env.example                   nomes das configurações locais
.gitignore                     proteção de credenciais e dumps
```
