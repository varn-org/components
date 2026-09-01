-- conversions between the three request surfaces a chat model can be addressed through, so one adapter set serves all of them
local json = require("json")

local shapes = {}

local stopReasons = {
    stop = "end_turn",
    length = "max_tokens",
    tool_calls = "tool_use",
    content_filter = "refusal",
}

-- the message surface names a system prompt beside the conversation and carries content as blocks
function shapes.messagesToChat(request)
    local chat = {}
    for key, value in pairs(request) do
        chat[key] = value
    end

    local messages = {}

    if request.system then
        local system = request.system
        if type(system) == "table" then
            local text = {}
            for _, block in ipairs(system) do
                text[#text + 1] = block.text
            end
            system = table.concat(text, "\n")
        end
        messages[#messages + 1] = { role = "system", content = system }
    end

    for _, message in ipairs(request.messages or {}) do
        if type(message.content) ~= "table" then
            messages[#messages + 1] = { role = message.role, content = message.content }
        else
            local parts = {}
            local toolCalls = {}
            local results = {}

            for _, block in ipairs(message.content) do
                if block.type == "text" then
                    parts[#parts + 1] = { type = "text", text = block.text }
                elseif block.type == "image" then
                    local source = block.source or {}
                    local url = source.url
                    if source.type == "base64" then
                        url = string.format("data:%s;base64,%s", source.media_type, source.data)
                    end
                    parts[#parts + 1] = { type = "image_url", image_url = { url = url } }
                elseif block.type == "tool_use" then
                    toolCalls[#toolCalls + 1] = {
                        index = #toolCalls,
                        id = block.id,
                        type = "function",
                        ["function"] = { name = block.name, arguments = json.encode(block.input or {}) },
                    }
                elseif block.type == "tool_result" then
                    results[#results + 1] = { role = "tool", tool_call_id = block.tool_use_id, content = block.content }
                end
            end

            -- a tool result is its own turn in the chat surface and has to follow the call directly, so it is emitted before any text that shared its message
            for _, result in ipairs(results) do
                messages[#messages + 1] = result
            end

            if #parts > 0 or #toolCalls > 0 then
                local turn = { role = message.role }
                if #parts > 0 then
                    turn.content = #parts == 1 and parts[1].type == "text" and parts[1].text or parts
                end
                if #toolCalls > 0 then
                    turn.tool_calls = toolCalls
                end
                messages[#messages + 1] = turn
            end
        end
    end

    chat.messages = messages
    chat.system = nil
    chat.stop_sequences = nil
    chat.stop = request.stop_sequences or request.stop

    if request.tools then
        local tools = {}
        for _, tool in ipairs(request.tools) do
            tools[#tools + 1] = {
                type = "function",
                ["function"] = { name = tool.name, description = tool.description, parameters = tool.input_schema },
            }
        end
        chat.tools = tools
    end

    local choice = request.tool_choice
    if type(choice) == "table" then
        if choice.type == "auto" then
            chat.tool_choice = "auto"
        elseif choice.type == "any" then
            chat.tool_choice = "required"
        elseif choice.type == "none" then
            chat.tool_choice = "none"
        elseif choice.type == "tool" then
            chat.tool_choice = { type = "function", ["function"] = { name = choice.name } }
        end
    end

    return chat
end

function shapes.chatToMessages(response)
    local message = response.choices and response.choices[1] and response.choices[1].message or {}
    local content = {}

    if message.content and message.content ~= "" then
        content[#content + 1] = { type = "text", text = message.content }
    end

    for _, call in ipairs(message.tool_calls or {}) do
        local fn = call["function"] or {}
        content[#content + 1] = {
            type = "tool_use",
            id = call.id,
            name = fn.name,
            input = fn.arguments and fn.arguments ~= "" and json.decode(fn.arguments) or {},
        }
    end

    local finish = response.choices and response.choices[1] and response.choices[1].finish_reason
    local usage = response.usage or {}

    return {
        id = response.id,
        type = "message",
        role = "assistant",
        model = response.model,
        content = content,
        stop_reason = stopReasons[finish] or finish,
        stop_sequence = nil,
        usage = { input_tokens = usage.prompt_tokens, output_tokens = usage.completion_tokens },
    }
end

-- the response surface takes a single input rather than a conversation, and names the system prompt instructions
function shapes.responsesToChat(request)
    local chat = {}
    for key, value in pairs(request) do
        chat[key] = value
    end

    local messages = {}

    if request.instructions then
        messages[#messages + 1] = { role = "system", content = request.instructions }
    end

    local input = request.input
    if type(input) == "string" then
        messages[#messages + 1] = { role = "user", content = input }
    else
        for _, item in ipairs(input or {}) do
            if item.type == "message" or item.role then
                local content = item.content
                if type(content) == "table" then
                    local parts = {}
                    for _, part in ipairs(content) do
                        if part.type == "input_text" or part.type == "output_text" or part.type == "text" then
                            parts[#parts + 1] = { type = "text", text = part.text }
                        elseif part.type == "input_image" then
                            parts[#parts + 1] = { type = "image_url", image_url = { url = part.image_url } }
                        end
                    end
                    content = parts
                end
                messages[#messages + 1] = { role = item.role or "user", content = content }
            end
        end
    end

    chat.messages = messages
    chat.input = nil
    chat.instructions = nil
    chat.max_output_tokens = nil
    chat.max_tokens = request.max_output_tokens or request.max_tokens

    -- this surface declares a function flat while the chat wire nests it, so a tool definition is rebuilt rather than forwarded
    if request.tools then
        local tools = {}
        for _, tool in ipairs(request.tools) do
            if tool.type == "function" and tool.name then
                tools[#tools + 1] = {
                    type = "function",
                    ["function"] = { name = tool.name, description = tool.description, parameters = tool.parameters },
                }
            else
                tools[#tools + 1] = tool
            end
        end
        chat.tools = tools
    end

    return chat
end

function shapes.chatToResponses(response)
    local choice = response.choices and response.choices[1] or {}
    local message = choice.message or {}
    local output = {}

    if message.content and message.content ~= "" then
        output[#output + 1] = {
            type = "message",
            id = response.id,
            role = "assistant",
            status = "completed",
            content = { { type = "output_text", text = message.content, annotations = {} } },
        }
    end

    for _, call in ipairs(message.tool_calls or {}) do
        local fn = call["function"] or {}
        output[#output + 1] = {
            type = "function_call",
            id = call.id,
            call_id = call.id,
            name = fn.name,
            arguments = fn.arguments,
            status = "completed",
        }
    end

    local usage = response.usage or {}

    return {
        id = response.id,
        object = "response",
        created_at = response.created,
        model = response.model,
        status = choice.finish_reason == "length" and "incomplete" or "completed",
        output = output,
        output_text = message.content,
        usage = {
            input_tokens = usage.prompt_tokens,
            output_tokens = usage.completion_tokens,
            total_tokens = usage.total_tokens,
        },
    }
end

return shapes
