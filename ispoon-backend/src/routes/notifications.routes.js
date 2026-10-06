import express from "express";
import { protect } from "../middleware/authMiddleware.js";
import * as NotificationController from "../controllers/notificationController.js";
import { validateRequest } from "../middleware/validateRequest.js";
import {
    notificationHistorySchema,
    notificationIdSchema,
    notificationPreferencesSchema,
    registerFCMTokenSchema,
} from "../validators/notification.schema.js";

const router = express.Router();

// All notification routes require authentication.
router.use(protect);

// Preferences management
router.get("/preferences", NotificationController.getPreferences);
router.put("/preferences", validateRequest(notificationPreferencesSchema), NotificationController.updatePreferences);

// FCM token registration
router.post("/fcm-token", validateRequest(registerFCMTokenSchema), NotificationController.registerFCMToken);

// Notification history
router.get("/history", validateRequest(notificationHistorySchema), NotificationController.getHistory);

// Notification tracking
router.post("/:id/opened", validateRequest(notificationIdSchema), NotificationController.markOpened);
router.post("/:id/action", validateRequest(notificationIdSchema), NotificationController.markActionTaken);

export default router;

