export class DefaultAzureCredential {
  async getToken() {
    return { token: 'fake-token' };
  }
}
