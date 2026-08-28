import {
  createCipheriv,
  createDecipheriv,
  createHmac,
  randomBytes
} from 'node:crypto';

export class IdentityProtector {
  private readonly key: Buffer;

  constructor(hexKey: string) {
    if (!/^[0-9a-fA-F]{64}$/.test(hexKey)) {
      throw new Error('Identity encryption key must be 64 hexadecimal characters');
    }
    this.key = Buffer.from(hexKey, 'hex');
  }

  encrypt(value: string): string {
    const iv = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', this.key, iv);
    const encrypted = Buffer.concat([cipher.update(value, 'utf8'), cipher.final()]);
    const tag = cipher.getAuthTag();
    return [iv, tag, encrypted].map((part) => part.toString('base64url')).join('.');
  }

  decrypt(value: string): string {
    const parts = value.split('.');
    if (parts.length !== 3) {
      throw new Error('Encrypted identity has an invalid format');
    }
    const iv = Buffer.from(parts[0], 'base64url');
    const tag = Buffer.from(parts[1], 'base64url');
    const encrypted = Buffer.from(parts[2], 'base64url');
    const decipher = createDecipheriv('aes-256-gcm', this.key, iv);
    decipher.setAuthTag(tag);
    return Buffer.concat([decipher.update(encrypted), decipher.final()]).toString('utf8');
  }

  digest(value: string): string {
    return createHmac('sha256', this.key).update(value, 'utf8').digest('hex');
  }
}
