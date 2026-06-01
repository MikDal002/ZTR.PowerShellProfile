{{scope}} and pretend you're a senior dev doing a code review, and you HATE this implementation. What would you criticize? What edge cases am I missing? 
 
Every comment write to separate {number}-{slug}.md file. under /.review/ folder. Number is just a next unique number, like a local id.
 
Every file should have a structure like a proper review comment on github: 
- Location - put the problem context, where to find an issue you are criticizing. Say what this/those lines of code were supposed to do.
  Put at least one line before and one line after. You can add more lines if it is needed for context.
- Say what is wrong and why in a professional way. 
- Propose a solution. If appropriate provide a code block. But only for simple changes.
- Do not touch actual code. you can only create those md files under /.review/ folder.
- Assess importance of the comment review in scale from 1 to 6, when 6 is an excellent, easy to implement and very valuable improvement and 1 is a poor idea, which you are unsure.
- Keep lines short, to keep them readable in narrow window.

## Example of expected output
Please format your response exactly like the example below for every issue you find.

Filename:
/.review/01-inefficient-memory-filtering.md
````md
    # Location and context
    `Controllers/OrderController.cs:29-35`
    
    This block is supposed to retrieve a user's orders asynchronously, calculate the 
    total amount, and return it as an API response.
    
    ```csharp
    28:  // Get user orders and calculate total
    29:  [HttpGet("{userId}/summary")]
    30:  public IActionResult GetOrderSummary(int userId)
    31:  {
    32:      var orders = _orderService.GetOrdersAsync(userId).Result;
    33:      var total = orders.Sum(o => o.Amount);
    34:      return Ok(new { UserId = userId, Total = total });
    35:  }
    36:
    ```
    
    # What is wrong
    Using `.Result` (or `.Wait()`) on an asynchronous Task inside a synchronous method 
    is a fatal architectural flaw known as "sync-over-async". By blocking the current 
    thread while waiting for the Task to complete, you are holding a thread hostage. 
    In an ASP.NET Core environment, doing this prevents the thread from returning to 
    the Thread Pool to serve other requests.

    The critical edge case you are missing here is application behavior under load. 
    While this works fine on your local machine with 1 user, during peak traffic, 
    a burst of concurrent requests will instantly exhaust the Thread Pool. This will 
    cause a deadlock or thread pool starvation, bringing the entire application to 
    a grinding halt (503 Service Unavailable). This implementation is actively dangerous 
    to system stability.
  
    # Proposed solution
  
    Embrace "async all the way down". Change the controller action to be asynchronous 
    and use the await keyword so the thread is yielded back to the pool during the 
    I/O operation.
  
    ```csharp
    [HttpGet("{userId}/summary")]
    public async Task<IActionResult> GetOrderSummary(int userId)
    {
        var orders = await _orderService.GetOrdersAsync(userId);
        var total = orders.Sum(o => o.Amount);
        return Ok(new { UserId = userId, Total = total });
    }
    ```

    # Assessment
    6/6 - it is easy to do and makes a code clean.
````

If you think that, the PR is doing way too much, propose in separate file how to split it into smaller ones.
Order them from smallest to biggest.