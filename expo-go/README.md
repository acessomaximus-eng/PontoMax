# PontoMax no Expo Go

Abre o PontoMax completo no celular pelo **Expo Go**, lendo o QR Code do `npx expo start` — sem instalar APK.

> O app principal é feito em Flutter (pasta `app/`). Este projeto Expo é uma "casca" que exibe o app web do PontoMax (servido em `/app`) com GPS e câmera liberados — as telas e as regras são as mesmas.

## Como usar

1. Suba o PontoMax no computador (veja [docs/como-rodar.md](../docs/como-rodar.md)):
   ```bash
   docker compose up -d --build
   ```
2. Instale o **Expo Go** no celular (Play Store / App Store).
3. No computador, com [Node.js 20+](https://nodejs.org):
   ```bash
   cd expo-go
   npm install
   npx expo start
   ```
4. Leia o **QR Code** que aparece no terminal: no Android pelo próprio Expo Go, no iPhone pela câmera.

O app usa automaticamente o IP do computador que mostrou o QR Code, na porta **8080**. Celular e computador precisam estar no **mesmo Wi-Fi** (se não conectar, libere as portas 8080 e 8081 no firewall, ou use `npx expo start --tunnel`).

Para apontar para outro servidor (ex.: produção):

```bash
EXPO_PUBLIC_PONTOMAX_URL=https://ponto.suaempresa.com.br npx expo start
```

Login de demonstração: `admin@pontomax.app` / `pontomax123`.
