using Microsoft.AspNetCore.Mvc;
using GrubifyApi.Models;

namespace GrubifyApi.Controllers
{
    [ApiController]
    [Route("api/[controller]")]
    public class FoodItemsController : ControllerBase
    {
        private static readonly List<FoodItem> FoodItems = new()
        {
            // Tony's Italian Bistro items
            new FoodItem
            {
                Id = 1,
                Name = "Margherita Pizza",
                Description = "Classic pizza with fresh tomatoes, mozzarella, and basil",
                Price = 16.99m,
                ImageUrl = "https://images.unsplash.com/photo-1604382354936-07c5d9983bd3?w=400&h=300&fit=crop",
                Category = "Pizza",
                IsVegetarian = true,
                IsVegan = false,
                IsSpicy = false,
                RestaurantId = 1,
                PreparationTime = 20
            },
            new FoodItem
            {
                Id = 2,
                Name = "Chicken Alfredo",
                Description = "Creamy fettuccine pasta with grilled chicken and parmesan",
                Price = 19.99m,
                ImageUrl = "https://images.unsplash.com/photo-1621996346565-e3dbc353d2e5?w=400&h=300&fit=crop",
                Category = "Pasta",
                IsVegetarian = false,
                IsVegan = false,
                IsSpicy = false,
                RestaurantId = 1,
                PreparationTime = 25
            },
            new FoodItem
            {
                Id = 3,
                Name = "Caesar Salad",
                Description = "Crisp romaine lettuce with caesar dressing and croutons",
                Price = 12.99m,
                ImageUrl = "https://images.unsplash.com/photo-1546793665-c74683f339c1?w=400&h=300&fit=crop",
                Category = "Salad",
                IsVegetarian = true,
                IsVegan = false,
                IsSpicy = false,
                RestaurantId = 1,
                PreparationTime = 10
            },

            // Sakura Sushi items
            new FoodItem
            {
                Id = 4,
                Name = "California Roll",
                Description = "Fresh avocado, cucumber, and crab meat with sesame seeds",
                Price = 14.99m,
                ImageUrl = "https://images.unsplash.com/photo-1579584425555-c3ce17fd4351?w=400&h=300&fit=crop",
                Category = "Sushi",
                IsVegetarian = false,
                IsVegan = false,
                IsSpicy = false,
                RestaurantId = 2,
                PreparationTime = 15
            },
            new FoodItem
            {
                Id = 5,
                Name = "Spicy Tuna Roll",
                Description = "Fresh tuna with spicy mayo and sriracha",
                Price = 16.99m,
                ImageUrl = "https://images.unsplash.com/photo-1617196034796-73dfa7b1fd56?w=400&h=300&fit=crop",
                Category = "Sushi",
                IsVegetarian = false,
                IsVegan = false,
                IsSpicy = true,
                RestaurantId = 2,
                PreparationTime = 15
            },
            new FoodItem
            {
                Id = 6,
                Name = "Chicken Teriyaki Bowl",
                Description = "Grilled chicken with teriyaki sauce over steamed rice",
                Price = 18.99m,
                ImageUrl = "https://images.unsplash.com/photo-1546069901-eacef0df6022?w=400&h=300&fit=crop",
                Category = "Bowl",
                IsVegetarian = false,
                IsVegan = false,
                IsSpicy = false,
                RestaurantId = 2,
                PreparationTime = 20
            },

            // Spice Garden items
            new FoodItem
            {
                Id = 7,
                Name = "Chicken Tikka Masala",
                Description = "Tender chicken in a creamy tomato-based curry sauce",
                Price = 17.99m,
                ImageUrl = "https://images.unsplash.com/photo-1565557623262-b51c2513a641?w=400&h=300&fit=crop",
                Category = "Curry",
                IsVegetarian = false,
                IsVegan = false,
                IsSpicy = true,
                RestaurantId = 3,
                PreparationTime = 30
            },
            new FoodItem
            {
                Id = 8,
                Name = "Vegetable Biryani",
                Description = "Fragrant basmati rice with mixed vegetables and aromatic spices",
                Price = 15.99m,
                ImageUrl = "https://images.unsplash.com/photo-1563379091339-03246963d17a?w=400&h=300&fit=crop",
                Category = "Rice",
                IsVegetarian = true,
                IsVegan = true,
                IsSpicy = true,
                RestaurantId = 3,
                PreparationTime = 25
            },
            new FoodItem
            {
                Id = 9,
                Name = "Garlic Naan",
                Description = "Fresh baked bread with garlic and herbs",
                Price = 4.99m,
                ImageUrl = "https://images.unsplash.com/photo-1601050690597-df0568f70950?w=400&h=300&fit=crop",
                Category = "Bread",
                IsVegetarian = true,
                IsVegan = false,
                IsSpicy = false,
                RestaurantId = 3,
                PreparationTime = 10
            },

            // Burger Hub items
            new FoodItem
            {
                Id = 10,
                Name = "Classic Cheeseburger",
                Description = "Beef patty with cheese, lettuce, tomato, and special sauce",
                Price = 13.99m,
                ImageUrl = "https://images.unsplash.com/photo-1568901346375-23c9450c58cd?w=400&h=300&fit=crop",
                Category = "Burger",
                IsVegetarian = false,
                IsVegan = false,
                IsSpicy = false,
                RestaurantId = 4,
                PreparationTime = 15
            },
            new FoodItem
            {
                Id = 11,
                Name = "Crispy Chicken Sandwich",
                Description = "Fried chicken breast with coleslaw and pickles",
                Price = 15.99m,
                ImageUrl = "https://images.unsplash.com/photo-1606755962773-d324e9a13086?w=400&h=300&fit=crop",
                Category = "Sandwich",
                IsVegetarian = false,
                IsVegan = false,
                IsSpicy = false,
                RestaurantId = 4,
                PreparationTime = 18
            },
            new FoodItem
            {
                Id = 12,
                Name = "Sweet Potato Fries",
                Description = "Crispy sweet potato fries with sea salt",
                Price = 6.99m,
                ImageUrl = "https://images.unsplash.com/photo-1573080496219-bb080dd4f877?w=400&h=300&fit=crop",
                Category = "Sides",
                IsVegetarian = true,
                IsVegan = true,
                IsSpicy = false,
                RestaurantId = 4,
                PreparationTime = 12
            },

            // Green Bowl items
            new FoodItem
            {
                Id = 13,
                Name = "Quinoa Buddha Bowl",
                Description = "Quinoa with roasted vegetables, avocado, and tahini dressing",
                Price = 14.99m,
                ImageUrl = "https://images.unsplash.com/photo-1512621776951-a57141f2eefd?w=400&h=300&fit=crop",
                Category = "Bowl",
                IsVegetarian = true,
                IsVegan = true,
                IsSpicy = false,
                RestaurantId = 5,
                PreparationTime = 15
            },
            new FoodItem
            {
                Id = 14,
                Name = "Acai Berry Smoothie",
                Description = "Acai berries blended with banana and coconut milk",
                Price = 8.99m,
                ImageUrl = "https://images.unsplash.com/photo-1553530666-ba11a7da3888?w=400&h=300&fit=crop",
                Category = "Smoothie",
                IsVegetarian = true,
                IsVegan = true,
                IsSpicy = false,
                RestaurantId = 5,
                PreparationTime = 5
            },
            new FoodItem
            {
                Id = 15,
                Name = "Grilled Salmon Salad",
                Description = "Fresh salmon over mixed greens with lemon vinaigrette",
                Price = 18.99m,
                ImageUrl = "https://images.unsplash.com/photo-1540420773420-3366772f4999?w=400&h=300&fit=crop",
                Category = "Salad",
                IsVegetarian = false,
                IsVegan = false,
                IsSpicy = false,
                RestaurantId = 5,
                PreparationTime = 20
            }
        };

        [HttpGet]
        public ActionResult<IEnumerable<FoodItem>> GetFoodItems()
        {
            return Ok(FoodItems);
        }

        [HttpGet("{id}")]
        public ActionResult<FoodItem> GetFoodItem(int id)
        {
            var foodItem = FoodItems.FirstOrDefault(f => f.Id == id);
            if (foodItem == null)
            {
                return NotFound();
            }
            return Ok(foodItem);
        }

        [HttpGet("restaurant/{restaurantId}")]
        public ActionResult<IEnumerable<FoodItem>> GetFoodItemsByRestaurant(int restaurantId)
        {
            var items = FoodItems.Where(f => f.RestaurantId == restaurantId).ToList();
            return Ok(items);
        }

        [HttpGet("category/{category}")]
        public ActionResult<IEnumerable<FoodItem>> GetFoodItemsByCategory(string category)
        {
            var items = FoodItems.Where(f => 
                f.Category.Equals(category, StringComparison.OrdinalIgnoreCase)).ToList();
            return Ok(items);
        }

        [HttpGet("search")]
        public ActionResult<IEnumerable<FoodItem>> SearchFoodItems([FromQuery] string query)
        {
            if (string.IsNullOrEmpty(query))
            {
                return Ok(FoodItems);
            }

            var items = FoodItems.Where(f => 
                f.Name.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                f.Description.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                f.Category.Contains(query, StringComparison.OrdinalIgnoreCase)).ToList();
            
            return Ok(items);
        }

        [HttpGet("dietary")]
        public ActionResult<IEnumerable<FoodItem>> GetFoodItemsByDietaryPreference(
            [FromQuery] bool? isVegetarian = null,
            [FromQuery] bool? isVegan = null,
            [FromQuery] bool? isSpicy = null)
        {
            var items = FoodItems.AsQueryable();

            if (isVegetarian.HasValue)
                items = items.Where(f => f.IsVegetarian == isVegetarian.Value);

            if (isVegan.HasValue)
                items = items.Where(f => f.IsVegan == isVegan.Value);

            if (isSpicy.HasValue)
                items = items.Where(f => f.IsSpicy == isSpicy.Value);

            return Ok(items.ToList());
        }
    }
}
