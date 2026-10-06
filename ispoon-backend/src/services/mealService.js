import * as MealModel from "../models/mealModel.js";
import * as DeviceModel from "../models/deviceModel.js";
import { AppError } from "../utils/errors.js";

class MealService {
    async getUserMeals(userId, queryOptions) {
        const {
            limit = 20,
            offset = 0,
            meal_type,
            mealType,
            sort_by,
            include_bites,
            before_started_at,
            before_id,
        } = queryOptions;
        return await MealModel.getUserMeals(userId, {
            limit,
            offset,
            mealType: meal_type ?? mealType,
            sort_by,
            include_bites,
            before_started_at,
            before_id,
        });
    }

    async getMealDetails(mealId, userId) {
        const meal = await MealModel.getUserMealById(mealId, userId);
        if (!meal) throw new AppError('Meal not found', 404);
        return meal;
    }

    async createMeal(mealData, userId) {
        await this.#assertDeviceBelongsToUser(mealData.device_id, userId);

        // Use upsert when uuid is present so repeated syncs of the same meal
        // don't create duplicates — idempotent sync is safe to retry
        if (mealData.uuid) {
            const meal = await MealModel.upsertMealByUuid({ ...mealData, user_id: userId });
            if (!meal) {
                throw new AppError('Meal not found', 404);
            }
            return meal;
        }
        const meal = await MealModel.createMeal({ ...mealData, user_id: userId });
        if (!meal) throw new AppError('Device not found or access denied', 404);
        return meal;
    }

    async #assertDeviceBelongsToUser(deviceId, userId) {
        if (!deviceId) return;
        const device = await DeviceModel.getUserDeviceById(userId, deviceId);
        if (!device) {
            throw new AppError('Device not found or access denied', 404);
        }
    }

    async updateMeal(mealId, userId, updateData) {
        const meal = await MealModel.updateMeal(mealId, userId, updateData);
        if (!meal) throw new AppError('Meal not found', 404);
        return meal;
    }

    async deleteMeal(mealId, userId) {
        const deleted = await MealModel.deleteMeal(mealId, userId);
        if (!deleted) throw new AppError('Meal not found', 404);
        return { success: true, message: 'Meal deleted successfully' };
    }

    async updateMealTemperature(mealId, userId, temperatureData) {
        const meal = await MealModel.updateMeal(mealId, userId, {
            avg_food_temp_c: temperatureData.avg_food_temp_c,
        });
        if (!meal) throw new AppError('Meal not found', 404);
        return meal;
    }
}

export default new MealService();
