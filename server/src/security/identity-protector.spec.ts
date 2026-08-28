import { IdentityProtector } from './identity-protector';

describe('IdentityProtector', () => {
  const key = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  it('encrypts and decrypts an identity without exposing plaintext', () => {
    const protector = new IdentityProtector(key);

    const encrypted = protector.encrypt('HuaweiUnionIdValue');

    expect(encrypted).not.toContain('HuaweiUnionIdValue');
    expect(protector.decrypt(encrypted)).toBe('HuaweiUnionIdValue');
  });

  it('creates a stable keyed digest for identity lookup', () => {
    const protector = new IdentityProtector(key);

    expect(protector.digest('HuaweiUnionIdValue')).toBe(
      protector.digest('HuaweiUnionIdValue')
    );
    expect(protector.digest('HuaweiUnionIdValue')).not.toBe(
      protector.digest('AnotherUnionId')
    );
  });

  it('rejects tampered ciphertext', () => {
    const protector = new IdentityProtector(key);
    const encrypted = protector.encrypt('HuaweiUnionIdValue');
    const tampered = `${encrypted.slice(0, -1)}${encrypted.endsWith('A') ? 'B' : 'A'}`;

    expect(() => protector.decrypt(tampered)).toThrow();
  });
});
