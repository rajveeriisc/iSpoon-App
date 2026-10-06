import * as BiteModel from "../models/biteModel.js";
import * as MealModel from "../models/mealModel.js";
import { AppError } from "../utils/errors.js";

class BiteService {
    async syncBites(mealUuid, userId, bitesData) {
        if (!Array.isArray(bitesData) || bitesData.length === 0) {
            throw new AppError('bites array is required and must not be empty', 400);
        }

        const { mealOwnerId, rows } = await BiteModel.upsertBites(mealUuid, userId, bitesData);
        // Uniform 404 so clients cannot probe whether a meal UUID exists.
        if (mealOwnerId == null || Number(mealOwnerId) !== Number(userId)) {
            throw new AppError('Meal not found', 404);
        }

        return {
            synced: rows.length,
            total: bitesData.length,
        };
    }

    async getBites(mealUuid, userId, options = {}) {
        const meal = await MealModel.getMealByUuid(mealUuid);
        if (!meal || Number(meal.user_id) !== Number(userId)) {
            throw new AppError('Meal not found', 404);
        }

        const bites = await BiteModel.getBitesForMeal(mealUuid, options);
        return bites;
    }
}

export default new BiteService();
