import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

class MobileEncryptionService {
  static const String _securityKey = 'iMmoRtALs';

  // MD5 hash the key — same as C# MD5CryptoServiceProvider
  static Uint8List _deriveKey(String key) {
    final keyBytes = utf8.encode(key);
    final digest = md5.convert(keyBytes);
    return Uint8List.fromList(digest.bytes);
  }

  // Triple DES, ECB mode, PKCS7 padding — matches C# TripleDESCryptoServiceProvider
  static PaddedBlockCipher _buildCipher(bool forEncryption) {
    final keyBytes = _deriveKey(_securityKey);
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      ECBBlockCipher(DESedeEngine()),
    );
    cipher.init(
      forEncryption,
      PaddedBlockCipherParameters(KeyParameter(keyBytes), null),
    );
    return cipher;
  }

  /// Decrypts a Base64-encoded mobile number encrypted by the C# Encrypt() method.
  static String? decrypt(String encryptedBase64) {
    try {
      final encryptedBytes = base64.decode(encryptedBase64);
      final cipher = _buildCipher(false);
      final decrypted = cipher.process(encryptedBytes);
      return utf8.decode(decrypted);
    } catch (e) {
      print('[MobileEncryptionService] Decrypt error: $e');
      return null;
    }
  }

  /// Encrypts a plain mobile number using the same algorithm as C# Encrypt().
  static String? encrypt(String plainText) {
    try {
      final plainBytes = Uint8List.fromList(utf8.encode(plainText));
      final cipher = _buildCipher(true);
      final encrypted = cipher.process(plainBytes);
      return base64.encode(encrypted);
    } catch (e) {
      print('[MobileEncryptionService] Encrypt error: $e');
      return null;
    }
  }
}
