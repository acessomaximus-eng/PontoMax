import Constants from 'expo-constants';
import * as Location from 'expo-location';
import { StatusBar } from 'expo-status-bar';
import { useCallback, useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  BackHandler,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaView, SafeAreaProvider } from 'react-native-safe-area-context';
import { WebView } from 'react-native-webview';

const BRAND = '#1E40AF';

/**
 * Endereço do servidor PontoMax.
 *
 * 1. `EXPO_PUBLIC_PONTOMAX_URL` (ex.: https://ponto.suaempresa.com.br);
 * 2. senão, o mesmo computador que roda o `npx expo start` (o IP vem do QR
 *    Code lido pelo Expo Go), na porta 8080 do `docker compose`.
 */
function defaultServer(): string {
  const configured = process.env.EXPO_PUBLIC_PONTOMAX_URL;
  if (configured) return normalize(configured);
  const host = Constants.expoConfig?.hostUri?.split(':')[0];
  return host ? `http://${host}:8080` : '';
}

function normalize(url: string): string {
  let u = url.trim().replace(/\/+$/, '').replace(/\/app$/, '');
  if (u && !/^https?:\/\//.test(u)) u = `http://${u}`;
  return u;
}

type Status = 'checking' | 'ready' | 'error';

export default function App() {
  return (
    <SafeAreaProvider>
      <Main />
    </SafeAreaProvider>
  );
}

function Main() {
  const [server, setServer] = useState(defaultServer);
  const [draft, setDraft] = useState(server);
  const [status, setStatus] = useState<Status>('checking');
  const [error, setError] = useState('');
  const web = useRef<WebView>(null);
  const canGoBack = useRef(false);

  // O GPS da página só funciona com a permissão concedida ao app.
  useEffect(() => {
    Location.requestForegroundPermissionsAsync().catch(() => undefined);
  }, []);

  const check = useCallback(async (url: string) => {
    if (!url) {
      setError('Informe o endereço do servidor PontoMax.');
      setStatus('error');
      return;
    }
    setStatus('checking');
    const timeout = new AbortController();
    const timer = setTimeout(() => timeout.abort(), 8000);
    try {
      const res = await fetch(`${url}/api/v1/health`, { signal: timeout.signal });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      setStatus('ready');
    } catch {
      setError(
        `Não foi possível conectar em ${url}.\n\n` +
          'Confira se o PontoMax está rodando no computador (docker compose up -d), ' +
          'se o celular está no mesmo Wi-Fi e se a porta 8080 está liberada no firewall.',
      );
      setStatus('error');
    } finally {
      clearTimeout(timer);
    }
  }, []);

  useEffect(() => {
    check(server);
  }, [server, check]);

  // Botão "voltar" do Android navega dentro do app.
  useEffect(() => {
    const sub = BackHandler.addEventListener('hardwareBackPress', () => {
      if (status === 'ready' && canGoBack.current) {
        web.current?.goBack();
        return true;
      }
      return false;
    });
    return () => sub.remove();
  }, [status]);

  if (status === 'ready') {
    return (
      <SafeAreaView style={styles.fill} edges={['top', 'bottom']}>
        <StatusBar style="dark" />
        <WebView
          ref={web}
          source={{ uri: `${server}/app/` }}
          style={styles.fill}
          originWhitelist={['*']}
          javaScriptEnabled
          domStorageEnabled
          geolocationEnabled
          allowsInlineMediaPlayback
          mediaCapturePermissionGrantType="grant"
          allowFileAccess
          setSupportMultipleWindows={false}
          startInLoadingState
          renderLoading={() => <Loading text="Abrindo o PontoMax…" />}
          onNavigationStateChange={(s) => (canGoBack.current = s.canGoBack)}
          onError={(e) => {
            setError(`Erro ao abrir o app: ${e.nativeEvent.description}`);
            setStatus('error');
          }}
        />
      </SafeAreaView>
    );
  }

  if (status === 'checking') return <Loading text={`Conectando em ${server}…`} />;

  return (
    <SafeAreaView style={styles.fill}>
      <StatusBar style="dark" />
      <KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : undefined} style={styles.setup}>
        <View style={styles.logo}>
          <Text style={styles.logoText}>P</Text>
        </View>
        <Text style={styles.title}>PontoMax</Text>
        <Text style={styles.error}>{error}</Text>
        <Text style={styles.label}>Endereço do servidor</Text>
        <TextInput
          value={draft}
          onChangeText={setDraft}
          placeholder="192.168.0.10:8080"
          autoCapitalize="none"
          autoCorrect={false}
          keyboardType="url"
          style={styles.input}
        />
        <Pressable
          style={styles.button}
          onPress={() => {
            const url = normalize(draft);
            setDraft(url);
            if (url === server) check(url);
            else setServer(url);
          }}
        >
          <Text style={styles.buttonText}>Conectar</Text>
        </Pressable>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

function Loading({ text }: { text: string }) {
  return (
    <View style={[styles.fill, styles.center]}>
      <ActivityIndicator size="large" color={BRAND} />
      <Text style={styles.muted}>{text}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1, backgroundColor: '#fff' },
  center: { alignItems: 'center', justifyContent: 'center', gap: 16 },
  setup: { flex: 1, padding: 24, justifyContent: 'center' },
  logo: {
    width: 64,
    height: 64,
    borderRadius: 16,
    backgroundColor: BRAND,
    alignItems: 'center',
    justifyContent: 'center',
    alignSelf: 'center',
  },
  logoText: { color: '#fff', fontSize: 32, fontWeight: '800' },
  title: { fontSize: 24, fontWeight: '800', textAlign: 'center', marginTop: 12, color: '#0F172A' },
  error: { color: '#B91C1C', marginVertical: 20, lineHeight: 20 },
  label: { fontWeight: '600', marginBottom: 6, color: '#334155' },
  input: {
    borderWidth: 1,
    borderColor: '#CBD5E1',
    borderRadius: 10,
    paddingHorizontal: 14,
    paddingVertical: 12,
    fontSize: 16,
  },
  button: { backgroundColor: BRAND, borderRadius: 10, paddingVertical: 14, marginTop: 16 },
  buttonText: { color: '#fff', textAlign: 'center', fontWeight: '700', fontSize: 16 },
  muted: { color: '#64748B', paddingHorizontal: 24, textAlign: 'center' },
});
