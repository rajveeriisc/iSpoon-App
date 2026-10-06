import BiteService from "../services/biteService.js";
import BaseController from "./BaseController.js";
import asyncHandler from "../utils/asyncHandler.js";
import logger from "../utils/logger.js";
import { AppError } from "../utils/errors.js";

/**
 * Bite Controller
 * POST /api/meals/:uuid/bites  — batch-upsert bites for a meal (sync from mobile)
 * GET  /api/meals/:uuid/bites  — fetch all bites for a meal
 */
class BiteController extends BaseController {
    constructor() {
        super();
    }

    // POST /api/meals/:uuid/bites
    syncBites = asyncHandler(async (req, res) => {
        const { uuid } = req.params;
        const userId = req.user.id;
        const { bites } = req.body;

        const result = await BiteService.syncBites(uuid, userId, bites);

        logger.info('Bites synced', {
            requestId: req.id,
            userId,
            mealUuid: uuid,
            received: result.total,
            inserted: result.synced,
        });

        this.handleSuccess(res, result, 'Bites synced', 201);
    });

    // GET /api/meals/:uuid/bites
    getBites = asyncHandler(async (req, res) => {
        const { uuid } = req.params;
        const userId = req.user.id;

        const limit = req.query.limit;
        const bites = await BiteService.getBites(uuid, userId, {
            limit,
            afterSequence: req.query.after_sequence,
        });
        this.handleSuccess(res, {
            bites,
            pagination: {
                limit,
                returned: bites.length,
                next_after_sequence: bites.length === limit
                    ? bites[bites.length - 1].sequence_number
                    : null,
            },
        });
    });
}

export default new BiteController();
