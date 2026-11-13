package org.nearbyshare.prototype

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.math.BigInteger
import java.net.InetSocketAddress
import java.net.Socket
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.Principal
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.Date
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509ExtendedKeyManager
import javax.net.ssl.X509TrustManager
import javax.security.auth.x500.X500Principal

internal class LocalTlsIdentity(val context: SSLContext, val certificate: X509Certificate) {
    val pin: String = MessageDigest.getInstance("SHA-256").digest(certificate.encoded)
        .joinToString("") { "%02x".format(it.toInt() and 255) }

    companion object {
        val protocols = arrayOf("TLSv1.2", "TLSv1.3")

        fun create(alias: String = "nearby-prototype-tls-ec-v2"): LocalTlsIdentity {
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            if (!store.containsAlias(alias)) {
                KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").apply {
                    initialize(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                        .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                        // Conscrypt hashes TLS transcripts before asking Keystore to sign.
                        // NONE authorizes signing that digest; TLS still uses SHA-256 or stronger.
                        // SHA256 also permits a valid self-signed certificate at generation time.
                        .setDigests(KeyProperties.DIGEST_NONE, KeyProperties.DIGEST_SHA256)
                        .setCertificateSubject(X500Principal("CN=Nearby prototype"))
                        .setCertificateSerialNumber(BigInteger(128, SecureRandom()).add(BigInteger.ONE))
                        .setCertificateNotBefore(Date(0)).setCertificateNotAfter(Date(4102444800000L))
                        .build())
                    generateKeyPair()
                }
            }
            val certificate = store.getCertificate(alias) as X509Certificate
            val key = store.getKey(alias, null) as PrivateKey
            // Select this identity explicitly. An upgraded installation can still contain
            // the old RSA alias, which a generic KeyManagerFactory might otherwise select.
            val manager = object : X509ExtendedKeyManager() {
                override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?) =
                    if (keyType == "EC") arrayOf(alias) else null
                override fun chooseServerAlias(keyType: String?, issuers: Array<out Principal>?, socket: Socket?) =
                    if (keyType == "EC") alias else null
                override fun chooseEngineServerAlias(keyType: String?, issuers: Array<out Principal>?, engine: SSLEngine?) =
                    if (keyType == "EC") alias else null
                override fun getCertificateChain(selected: String?) = if (selected == alias) arrayOf(certificate) else null
                override fun getPrivateKey(selected: String?) = if (selected == alias) key else null
                override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?): Array<String>? = null
                override fun chooseClientAlias(keyTypes: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?): String? = null
            }
            val context = SSLContext.getInstance("TLS").apply { init(arrayOf(manager), null, SecureRandom()) }
            return LocalTlsIdentity(context, certificate)
        }
    }
}

internal object TlsSelfTest {
    // Run against the actual server before displaying a QR. A successful bind does
    // not prove the hardware-backed private key can complete a TLS handshake.
    fun verify(identity: LocalTlsIdentity, port: Int, token: String,
               protocols: Array<String> = LocalTlsIdentity.protocols) {
        val trust = object : X509TrustManager {
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {
                throw CertificateException("Client authentication is not supported")
            }
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
                if (chain.isNullOrEmpty() || !MessageDigest.isEqual(chain[0].encoded, identity.certificate.encoded))
                    throw CertificateException("TLS self-check certificate mismatch")
            }
        }
        val client = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), SecureRandom()) }
        for (protocol in protocols) {
            (client.socketFactory.createSocket() as SSLSocket).use { socket ->
                socket.enabledProtocols = arrayOf(protocol)
                socket.soTimeout = 5000
                socket.connect(InetSocketAddress("127.0.0.1", port), 5000)
                socket.startHandshake()
                socket.outputStream.write(("GET /manifest HTTP/1.1\r\nHost: 127.0.0.1\r\n" +
                    "Authorization: Bearer $token\r\nConnection: close\r\n\r\n").toByteArray(Charsets.US_ASCII))
                socket.outputStream.flush()
                val status = socket.inputStream.bufferedReader(Charsets.US_ASCII).readLine()
                check(status?.startsWith("HTTP/1.1 200 ") == true) { "TLS self-check could not inspect sender ($protocol)" }
            }
        }
    }
}
