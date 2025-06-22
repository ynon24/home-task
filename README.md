
## How to Run

### Local (Mac / WSL for Windows)

1. **Clone the repository**
    ```bash
    git clone https://github.com/ynon24/home-task.git
    cd <YOUR-PROJECT-FOLDER>
    ```

2. **Configure your subscription**
    Edit the file `subscription.conf` and add your Azure subscription ID:
    ```
    AZURE_SUBSCRIPTION_ID=<your-subscription-id>
    ```

3. **Login to Azure**
    ```bash
    az login
    ```

4. **Make the deployment script executable**
    ```bash
    chmod +x deploy.sh
    ```

5. **Run the deployment**
    ```bash
    ./deploy.sh
    ```

> **Windows users:** Follow the same steps using **WSL** to run the commands.

### Run via GitHub Codespaces (or other GitHub workspace)

You can also run this code from GitHub Codespaces:

1. Open the repository in a Codespace.
2. In the Codespace terminal:
    - Add your subscription ID to `subscription.conf`.
    - Run `az login`.
    - Make the script executable and run it:
      ```bash
      chmod +x deploy.sh
      ./deploy.sh
      ```

## Access the Application

After the deployment is complete:

1. Get the external IP address of Traefik:
    ```bash
    kubectl get services -n traefik
    ```

2. Access your services:
    ```
    Service A: http://<EXTERNAL-IP>/service-a
    Service B: http://<EXTERNAL-IP>/service-b
    ```

## Notes

- The app uses Horizontal Pod Autoscalers (HPA) for dynamic scaling based on CPU and memory usage.
- Redis is used to store recent Bitcoin rate values for calculating the 10-minute average.
- Network policies are applied for service isolation and security.
