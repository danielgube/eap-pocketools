import java.net.HttpURLConnection;
import java.net.InetSocketAddress;
import java.net.Proxy;
import java.net.URI;
import java.net.URL;

public final class SslTrusterProbe {
    private static Proxy proxyFor(URI destination) throws Exception {
        String noProxy = System.getenv("NO_PROXY");
        if (noProxy == null || noProxy.isBlank()) {
            noProxy = System.getenv("no_proxy");
        }
        if (noProxy != null) {
            String host = destination.getHost().toLowerCase();
            for (String raw : noProxy.split(",")) {
                String item = raw.trim().toLowerCase();
                if (item.equals("*") || host.equals(item)
                        || (item.startsWith(".") && host.endsWith(item))) {
                    return Proxy.NO_PROXY;
                }
            }
        }
        String value = System.getenv("HTTPS_PROXY");
        if (value == null || value.isBlank()) {
            value = System.getenv("https_proxy");
        }
        if (value == null || value.isBlank()) {
            return Proxy.NO_PROXY;
        }
        URI proxy = URI.create(value);
        int port = proxy.getPort() >= 0 ? proxy.getPort() : 80;
        return new Proxy(
                Proxy.Type.HTTP,
                new InetSocketAddress(proxy.getHost(), port));
    }

    public static void main(String[] args) {
        if (args.length != 1) {
            System.err.println("usage: SslTrusterProbe.java URL");
            System.exit(2);
        }
        try {
            URI destination = URI.create(args[0]);
            URL url = destination.toURL();
            HttpURLConnection connection = (HttpURLConnection) url.openConnection(
                    proxyFor(destination));
            connection.setConnectTimeout(20000);
            connection.setReadTimeout(20000);
            connection.setInstanceFollowRedirects(true);
            connection.setRequestProperty("User-Agent", "EAP-SSLTruster/1.0");
            int status = connection.getResponseCode();
            if (!connection.getURL().getProtocol().equalsIgnoreCase("https")) {
                throw new IllegalStateException("redirect to a non-HTTPS URL");
            }
            System.out.println(status);
            connection.disconnect();
        } catch (Exception exception) {
            System.err.println(
                    exception.getClass().getSimpleName() + ": "
                            + exception.getMessage());
            System.exit(1);
        }
    }
}
