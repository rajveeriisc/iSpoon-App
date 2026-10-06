import express from "express";
import multer from "multer";
import sharp from "sharp";
import path from "path";
import fs from "fs";
import userController from "../controllers/userController.js";
import { protect } from "../middleware/authMiddleware.js";
import { validateRequest } from "../middleware/validateRequest.js";
import { updateProfileSchema } from "../validators/user.schema.js";
import { AppError } from "../utils/errors.js";

const router = express.Router();

// Image upload configuration
const configuredMaxFileSize = Number(process.env.MAX_FILE_SIZE);
const maxFileSize = Number.isSafeInteger(configuredMaxFileSize) && configuredMaxFileSize > 0
    ? Math.min(configuredMaxFileSize, 10 * 1024 * 1024)
    : 5 * 1024 * 1024;

const upload = multer({
    storage: multer.memoryStorage(),
    limits: {
        fileSize: maxFileSize,
        files: 1,
    },
    fileFilter: (_req, file, cb) => {
        const allowedMimeTypes = ["image/png", "image/jpeg", "image/jpg", "image/webp"];
        if (!allowedMimeTypes.includes(file.mimetype)) {
            return cb(new AppError("Only PNG, JPG, JPEG, and WebP images allowed", 400), false);
        }
        cb(null, true);
    },
});

// Image optimization middleware
const optimizeImage = async (req, res, next) => {
    if (!req.file) return next();

    try {
        const uploadsDir = path.join(process.cwd(), "uploads", "avatars");
        fs.mkdirSync(uploadsDir, { recursive: true });

        const filename = `u_${Date.now()}_${Math.random().toString(36).slice(2, 8)}.webp`;
        const filepath = path.join(uploadsDir, filename);

        await sharp(req.file.buffer)
            .resize(400, 400, { fit: "cover", position: "center" })
            .webp({ quality: 85 })
            .toFile(filepath);

        req.processedFile = {
            filename,
            path: filepath,
            url: `/uploads/avatars/${filename}`,
        };

        next();
    } catch (error) {
        next(new AppError("Invalid or unsupported image", 400));
    }
};

// All routes require authentication
router.get("/me", protect, userController.getMe);
router.put("/me", protect, validateRequest(updateProfileSchema), userController.updateMe);
router.post("/me/avatar", protect, upload.single("avatar"), optimizeImage, userController.uploadAvatar);
router.delete("/me/avatar", protect, userController.removeAvatar);

export default router;
