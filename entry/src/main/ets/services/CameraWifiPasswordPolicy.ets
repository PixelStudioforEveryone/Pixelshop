/** Personal camera hotspots only; enterprise/certificate networks need system settings. */
export class CameraWifiPasswordPolicy {
  static needsPassword(securityType: number): boolean {
    // SDK WifiSecurityType: OPEN=1, OWE=7 (encrypted without a shared password).
    return securityType !== 1 && securityType !== 7;
  }

  static supports(securityType: number): boolean {
    return securityType === 1 || securityType === 2 || securityType === 3 ||
      securityType === 4 || securityType === 7;
  }

  static validationError(securityType: number, password: string): string {
    if (!CameraWifiPasswordPolicy.supports(securityType)) return '该网络安全类型需要在系统 Wi-Fi 设置中连接';
    if (!CameraWifiPasswordPolicy.needsPassword(securityType)) return '';
    if (password.length === 0) return '请输入相机屏幕或网络设置中显示的 Wi-Fi 密码';
    if (/[\u0000-\u001f\u007f]/.test(password)) return '密码不能包含换行或控制字符';
    if (securityType === 2) {
      const ascii = /^[\x20-\x7e]+$/.test(password);
      if ((ascii && (password.length === 5 || password.length === 13)) ||
        (/^[0-9a-fA-F]+$/.test(password) && (password.length === 10 || password.length === 26))) return '';
      return 'WEP 密码需要 5 或 13 个字符，或 10 或 26 位十六进制密钥';
    }
    if (securityType === 3 && password.length < 8) return 'WPA/WPA2 密码至少需要 8 个字符';
    if (password.length > 63 && !(securityType === 3 && /^[0-9a-fA-F]{64}$/.test(password))) {
      return '密码最多 63 个字符；WPA/WPA2 也支持 64 位十六进制密钥';
    }
    return '';
  }

  static sameSsid(first: string, second: string): boolean {
    // SSIDs are case-sensitive. Keep internal spaces and the full camera suffix.
    const unquote = (ssid: string): string => ssid.length >= 2 && ssid.startsWith('"') && ssid.endsWith('"')
      ? ssid.substring(1, ssid.length - 1) : ssid;
    return first.length > 0 && second.length > 0 && unquote(first) === unquote(second);
  }
}
