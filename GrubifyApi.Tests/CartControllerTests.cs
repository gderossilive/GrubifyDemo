using System.Reflection;
using GrubifyApi.Controllers;
using GrubifyApi.Models;
using Microsoft.AspNetCore.Mvc;

namespace GrubifyApi.Tests;

public class CartControllerTests
{
    [Fact]
    public void AddItemToCart_RepeatedRequests_MergesQuantity()
    {
        var controller = new CartController();
        var userId = $"test-{Guid.NewGuid():N}";

        for (var index = 0; index < 32; index++)
        {
            var response = controller.AddItemToCart(userId, new AddCartItemRequest
            {
                FoodItemId = 1,
                Quantity = 1,
                SpecialInstructions = "No basil"
            });

            Assert.IsType<OkObjectResult>(response.Result);
        }

        var cartResult = Assert.IsType<OkObjectResult>(controller.GetCart(userId).Result);
        var cart = Assert.IsType<Cart>(cartResult.Value);
        var item = Assert.Single(cart.Items);

        Assert.Equal(32, item.Quantity);
        Assert.Equal("No basil", item.SpecialInstructions);
    }

    [Fact]
    public void CartController_DoesNotDeclareStaticRequestBufferCache()
    {
        var retainedBufferFields = typeof(CartController)
            .GetFields(BindingFlags.NonPublic | BindingFlags.Static)
            .Where(field => field.FieldType == typeof(List<byte[]>));

        Assert.Empty(retainedBufferFields);
    }
}
