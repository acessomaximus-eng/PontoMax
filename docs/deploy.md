# Deploy em produção

## Docker (qualquer servidor/VPS)

```bash
cp .env.example .env   # JWT_SECRET forte, PUBLIC_URL, SMTP, REP_INPI_NUMBER
docker compose up -d --build
```

Coloque um proxy HTTPS (Caddy, Nginx, Traefik) na frente da porta 8080. Faça backup diário do volume `db-data` (ou `pg_dump`) e do volume `storage` (fotos e anexos).

## Google Cloud (Cloud Run + Cloud SQL)

Aproveita créditos do Google Cloud e escala automaticamente.

```bash
PROJECT=meu-projeto
REGION=southamerica-east1          # São Paulo
gcloud config set project $PROJECT
gcloud services enable run.googleapis.com sqladmin.googleapis.com artifactregistry.googleapis.com secretmanager.googleapis.com

# Banco
gcloud sql instances create pontomax-db --database-version=POSTGRES_16 --region=$REGION --tier=db-g1-small
gcloud sql databases create pontomax --instance=pontomax-db
gcloud sql users create pontomax --instance=pontomax-db --password='SENHA_FORTE'

# Segredos
printf '%s' "$(openssl rand -hex 32)" | gcloud secrets create pontomax-jwt --data-file=-

# Imagem
gcloud artifacts repositories create pontomax --repository-format=docker --location=$REGION
gcloud builds submit --tag $REGION-docker.pkg.dev/$PROJECT/pontomax/app:latest .

# Serviço
gcloud run deploy pontomax \
  --image $REGION-docker.pkg.dev/$PROJECT/pontomax/app:latest \
  --region $REGION --allow-unauthenticated --port 8080 \
  --add-cloudsql-instances $PROJECT:$REGION:pontomax-db \
  --set-secrets JWT_SECRET=pontomax-jwt:latest \
  --set-env-vars "DATABASE_URL=postgres://pontomax:SENHA_FORTE@/pontomax?host=/cloudsql/$PROJECT:$REGION:pontomax-db,PONTOMAX_ENV=production,PUBLIC_URL=https://SEU_DOMINIO" \
  --min-instances 1
```

> Observações: (1) o chat usa long-polling em memória — com várias instâncias, troque o `EventBus` por `LISTEN/NOTIFY` do PostgreSQL ou Redis (ver roadmap); (2) no Cloud Run o disco é efêmero — monte um bucket do Cloud Storage em `/srv/storage` (`--add-volume type=cloud-storage`) para as fotos e anexos.

## Apps nativos

O workflow **Release multiplataforma** (`.github/workflows/release.yml`) gera APK/AAB (Android), IPA sem assinatura (iOS), Windows, macOS, Linux e Web. Defina a variável de repositório `PONTOMAX_API_URL` com o endereço público da API. Para publicar nas lojas, configure a assinatura (keystore Android e certificados Apple).

## Certificado digital (assinatura do AFD, AEJ e comprovantes)

A Portaria 671 exige o AFD e o AEJ assinados em CAdES (arquivo `.p7s` destacado) e o comprovante em PDF com PAdES. Configure um certificado **A1 ICP-Brasil** (e-CNPJ) do desenvolvedor do programa:

```bash
# Docker / servidor
SIGNING_CERT_PATH=/run/secrets/certificado.pfx
SIGNING_CERT_PASSWORD=senha-do-pfx

# Google Cloud Run: guarde o .pfx no Secret Manager e monte como arquivo
gcloud secrets create pontomax-cert --data-file=certificado.pfx
gcloud secrets create pontomax-cert-pass --data-file=- <<< 'senha-do-pfx'
gcloud run services update pontomax \
  --set-secrets=/certs/certificado.pfx=pontomax-cert:latest,SIGNING_CERT_PASSWORD=pontomax-cert-pass:latest \
  --set-env-vars=SIGNING_CERT_PATH=/certs/certificado.pfx
```

São aceitos `.pfx`/`.p12` no formato atual (AES/PBKDF2) e legado (3DES/RC2), ou PEM com certificado e chave. A tela **Relatórios** mostra o certificado em uso e avisa quando ele é autoassinado ou está vencido.
