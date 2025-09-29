import java.io.IOException;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.Scanner;

import com.google.auth.oauth2.GoogleCredentials;

public class GenerateOAuthAndRegistrationToken {
    public static void main(String[] args) throws IOException {
        // Step 1: Get service account path from environment variable
        String serviceAccountPath = System.getenv("GOOGLE_APPLICATION_CREDENTIALS");
        if (serviceAccountPath == null || serviceAccountPath.isEmpty()) {
            System.err.println("GOOGLE_APPLICATION_CREDENTIALS environment variable not set.");
            return;
        }
        GoogleCredentials credentials = GoogleCredentials
                .fromStream(new java.io.FileInputStream(serviceAccountPath))
                .createScoped("https://www.googleapis.com/auth/firebase.messaging");
        credentials.refreshIfExpired();
        String accessToken = credentials.getAccessToken().getTokenValue();
        System.out.println("OAuth2 Access Token: " + accessToken);

        // Step 2: Example HTTP POST request using the access token (like Postman)
        // Replace with your FCM endpoint and payload as needed
        String projectId = "vrukshamojani-4ffd6";
        String fcmUrl = "https://fcm.googleapis.com/v1/projects/" + projectId + "/messages:send";
        String payload = "{\"message\":{\"token\":\"f2aNJFLSSbKpTcmNMzHpCZ:APA91bE6RJkCELHV-ZIo98WLT76qrT6CdxZ7NJ-D8_kztJFXmE4uLIr8RbV7ayvhMNk2xTqI-ZV4z2_QzBD14Mx1ZvD_pWLkHBW6B3_N2cxVW206hLMC-ts\",\"notification\":{\"title\":\"Broadcast Message\",\"body\":\"Hello\"},\"data\":{\"phone\":\"+917208637122\"}}}";

        URL url = new URL(fcmUrl);
        HttpURLConnection conn = (HttpURLConnection) url.openConnection();
        conn.setRequestMethod("POST");
        conn.setRequestProperty("Authorization", "Bearer " + accessToken);
        conn.setRequestProperty("Content-Type", "application/json");
        conn.setDoOutput(true);
        conn.getOutputStream().write(payload.getBytes());

        int responseCode = conn.getResponseCode();
        System.out.println("FCM Response Code: " + responseCode);

        Scanner scanner = new Scanner(conn.getInputStream());
        while (scanner.hasNext()) {
            System.out.println(scanner.nextLine());
        }
        scanner.close();
    }
}
