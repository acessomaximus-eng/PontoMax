# Como rodar o PontoMax

O jeito mais simples é com o **Docker Desktop**: um único comando sobe o banco de dados, a API, o app web e o site.

## 1. No computador (Windows, macOS ou Linux)

1. Instale o [Docker Desktop](https://www.docker.com/products/docker-desktop/) e o [Git](https://git-scm.com/downloads) e abra o Docker Desktop.
2. Baixe o projeto e entre na branch de desenvolvimento:
   ```bash
   git clone https://github.com/acessomaximus-eng/PontoMax.git
   cd PontoMax
   git checkout claude/pontomax-app-dev-in2vii
   ```
3. Crie o arquivo de configuração com os dados de demonstração:
   ```bash
   cp .env.example .env
   ```
   Abra o `.env` num editor de texto e preencha:
   ```
   JWT_SECRET=qualquer-texto-longo-e-secreto-com-32-caracteres-ou-mais
   SEED_DEMO=true
   ```
4. Suba tudo (a primeira vez leva de 5 a 10 minutos, pois compila o app):
   ```bash
   docker compose up -d --build
   ```
5. Acesse no navegador:
   - **Site:** http://localhost:8080
   - **App web:** http://localhost:8080/app

### Logins de demonstração (senha `pontomax123`)

| Perfil | E-mail |
|---|---|
| Proprietário (vê tudo) | `admin@pontomax.app` |
| Gestor | `bruno@pontomax.app` |
| Colaboradores | `ana@pontomax.app`, `carlos@pontomax.app`, `daniela@pontomax.app`, `eduardo@pontomax.app`, `fernanda@pontomax.app` |

**Modo quiosque (tablet):** na tela de login toque em *Usar como quiosque*, informe o código `DEMO2026` e bata o ponto com a matrícula (`001` a `007`) e o PIN `1234`.

> Para bater o ponto como colaborador o navegador pede a localização: a empresa de demonstração exige estar no perímetro da "Loja Paulista" (Av. Paulista, São Paulo). Para testar de outro lugar, entre como `admin@pontomax.app` → **Empresa e regras** → desative *Exigir marcação dentro do perímetro*.

Comandos úteis: `docker compose logs -f app` (ver logs) · `docker compose down` (parar) · `docker compose down -v` (parar e apagar os dados).

## 2. No celular Android

1. No GitHub, abra **Actions** → a execução mais recente do **CI** na branch `claude/pontomax-app-dev-in2vii` → em *Artifacts* baixe **pontomax-android** (um .zip com o `app-release.apk`).
2. Copie o APK para o celular e instale (permita "instalar apps desconhecidos").
3. Com o celular **no mesmo Wi-Fi** do computador, descubra o IP do computador (Windows: `ipconfig`; macOS: Ajustes → Wi-Fi → Detalhes; Linux: `hostname -I`), por exemplo `192.168.0.10`.
4. No app, na tela de login, toque em **Servidor** e informe `192.168.0.10:8080`. Depois entre com um dos logins acima.

> Se o celular não conectar, libere a porta 8080 no firewall do computador.
> `http://` só é aceito para endereços da rede local; em produção use `https://`.

## 3. Outras plataformas

- **iPhone/iPad, Windows, macOS e Linux:** gere os instaladores em **Actions → Release → Run workflow** (os builds de iOS/macOS usam mais minutos do GitHub Actions). O app de iOS precisa de uma conta Apple Developer para instalar em aparelhos.
- **Desenvolvimento sem Docker** (Dart/Flutter e PostgreSQL instalados): veja a seção *Desenvolvimento* do [README](../README.md).

## 4. Colocar no ar para a empresa

Veja [deploy.md](deploy.md) (servidor com Docker ou Google Cloud Run + Cloud SQL), inclusive como configurar o certificado digital A1 que assina o AFD, o AEJ e os comprovantes.
