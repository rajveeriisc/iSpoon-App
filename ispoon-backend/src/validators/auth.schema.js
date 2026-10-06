import { z } from 'zod';

const tokenString = (name, max) => z.string()
    .min(1, `${name} is required`)
    .max(max, `${name} is too long`);

export const firebaseIdTokenSchema = z.object({
    body: z.object({
        idToken: tokenString('idToken', 16_384),
    }).strict(),
});

// The token may alternatively arrive in X-Refresh-Token. This schema still
// rejects unexpected JSON fields and bounds a body-provided token.
export const refreshTokenRequestSchema = z.object({
    body: z.object({
        refreshToken: tokenString('refreshToken', 8_192).optional(),
    }).strict().optional().default({}),
});

export const logoutRequestSchema = z.object({
    body: z.object({
        refreshToken: tokenString('refreshToken', 8_192).optional(),
        fcmToken: tokenString('fcmToken', 4_096).optional(),
    }).strict().optional().default({}),
});

export const deleteAccountSchema = z.object({
    body: z.object({
        // A freshly re-authenticated Firebase ID token. The access token still
        // authenticates the API request; this second proof authorizes the
        // irreversible operation.
        idToken: tokenString('idToken', 16_384),
    }).strict(),
});
