package org.nearbyshare.prototype

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.test.ext.junit.runners.AndroidJUnit4
import fi.iki.elonen.NanoHTTPD
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.IOException
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.UUID
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext

@RunWith(AndroidJUnit4::class)
class TlsHandshakeTest {
    private val aliases = mutableListOf<String>()
    private val token = "test-only-token"
    private fun alias() = "nearby-test-${UUID.randomUUID()}".also { aliases.add(it) }

    @After fun cleanUp() {
        KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.let { store ->
            aliases.forEach { store.deleteEntry(it) }
        }
    }

    private fun withServer(identity: LocalTlsIdentity, block: (Int) -> Unit) {
        val server = object : NanoHTTPD("127.0.0.1", 0) {
            override fun serve(session: IHTTPSession): Response {
                return if (session.uri == "/manifest" && session.headers["authorization"] == "Bearer $token")
                    newFixedLengthResponse(Response.Status.OK, "application/json", "{}")
                else newFixedLengthResponse(Response.Status.FORBIDDEN, "text/plain", "Pairing required")
            }
        }
        server.makeSecure(identity.context.serverSocketFactory, LocalTlsIdentity.protocols)
        try {
            server.start(5000, true)
            block(server.listeningPort)
        } finally { server.stop() }
    }

    @Test fun correctedKeyCompletesTLS12AndAuthorizedHTTPRequest() {
        val identity = LocalTlsIdentity.create(alias())
        withServer(identity) { TlsSelfTest.verify(identity, it, token, arrayOf("TLSv1.2")) }
    }

    @Test fun correctedKeyCompletesTLS13AndAuthorizedHTTPRequest() {
        val identity = LocalTlsIdentity.create(alias())
        withServer(identity) { TlsSelfTest.verify(identity, it, token, arrayOf("TLSv1.3")) }
    }

    @Test fun certificateMismatchIsRejected() {
        val sender = LocalTlsIdentity.create(alias())
        val differentIdentity = LocalTlsIdentity.create(alias())
        withServer(sender) { port ->
            try {
                TlsSelfTest.verify(differentIdentity, port, token)
                fail("A certificate different from the paired identity was accepted")
            } catch (_: IOException) { /* Expected TLS authentication failure. */ }
        }
    }

    @Test fun reopeningIdentityKeepsCertificateAndIgnoresLegacyRSAKey() {
        originalIdentity() // Reproduce an upgraded installation with the old alias present.
        val name = alias()
        val before = LocalTlsIdentity.create(name)
        val after = LocalTlsIdentity.create(name)
        assertEquals(before.pin, after.pin)
        assertEquals("EC", after.certificate.publicKey.algorithm)
        after.certificate.verify(after.certificate.publicKey)
        withServer(after) { TlsSelfTest.verify(after, it, token) }
    }

    // Preserve the original 0.1.0 key configuration here to reproduce the defect
    // on Android's real Conscrypt + Keystore, rather than a mocked JVM provider.
    private fun originalIdentity(): LocalTlsIdentity {
        val name = alias()
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, "AndroidKeyStore").apply {
            initialize(KeyGenParameterSpec.Builder(name, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                .setKeySize(2048).setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA512)
                .setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PKCS1, KeyProperties.SIGNATURE_PADDING_RSA_PSS)
                .build())
            generateKeyPair()
        }
        val managers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(store, null) }
        val context = SSLContext.getInstance("TLS").apply { init(managers.keyManagers, null, SecureRandom()) }
        return LocalTlsIdentity(context, store.getCertificate(name) as X509Certificate)
    }

    private fun assertOriginalHandshakeFails(protocol: String) {
        val identity = originalIdentity()
        withServer(identity) { port ->
            try {
                TlsSelfTest.verify(identity, port, token, arrayOf(protocol))
                fail("Original restricted RSA key unexpectedly completed $protocol")
            } catch (_: IOException) { /* Original signing permissions cannot complete TLS. */ }
        }
    }

    @Test fun originalRSAConfigurationFailsTLS12() = assertOriginalHandshakeFails("TLSv1.2")
    @Test fun originalRSAConfigurationFailsTLS13() = assertOriginalHandshakeFails("TLSv1.3")
}
