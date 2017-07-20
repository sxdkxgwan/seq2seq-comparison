function append_table(dest, inp)

  for i=1,#inp do
    table.insert(dest, inp[1])
  end

  return dest
end

function slice_table(src, index)
  local result = {}
  for i=index,#src do
    table.insert(result, src[i])
  end

  return result
end

function printMemProfile()
  free, total = cutorch.getMemoryUsage()
  print('GPU MEMORY FREE: ', free, 'of', total)
end

local first_hidden = {}

function LRP_saliency(
    alphabet,
    model,
    normalizer,
    sentence)

  local opt, encoder_clones, lookup = model.opt, model.clones, model.lookup

  -- Construct beginning hidden state
  for i=1,2*opt.num_layers do
    first_hidden[i] = first_hidden[i] or torch.CudaTensor()
    first_hidden[i]:resize(opt.rnn_size, opt.rnn_size):zero()
  end
  for i=2*opt.num_layers+1,#first_hidden do
    first_hidden[i] = nil
  end

  -- Forward pass
  local rnn_state = first_hidden
  for t=1,#sentence do
    local encoder_input = {lookup:forward(torch.CudaTensor{sentence[t]}:expand(opt.rnn_size))}
    append_table(encoder_input, rnn_state)
    rnn_state = encoder_clones[t]:forward(encoder_input)
  end

  -- Relevance
  local relevances = {}
  for i=1,2*opt.num_layers-1 do
    table.insert(
      relevances,
      torch.Tensor(opt.rnn_size, opt.rnn_size):zero():cuda()
    )
  end

  -- Relevance at point x is f(x) / var(f(x))
  table.insert(
    relevances,
    torch.diag(torch.cdiv(rnn_state[#rnn_state][1], normalizer[2][1])):cuda()
  )

  local relevance_state = relevances
  local input_relevances = {}
  for t=#sentence,1,-1 do
    relevance_state = LRP(encoder_clones[t], relevance_state)

    -- The input relevance state should now be a 500x500 vector representing
    -- total relevance over the word embedding. Summing over the second
    -- dimension will get us the desired relevances.
    input_relevances[t] = relevance_state[1]:sum(2):view(opt.rnn_size)
    relevance_state = slice_table(relevance_state, 2)
  end

  return input_relevances
end

function LRP(gmodule, R)
  local relevances = {}

  -- Topological sort of nodes in the
  -- gmodule
  local toposorted = {}
  local visited = {}

  function dfs(node)
    if visited[node] then
      return
    end
    visited[node] = true

    for dependency, t in pairs(node.data.reverseMap) do
      dfs(dependency)
    end

    table.insert(toposorted, node.data)
  end

  dfs(gmodule.innode)

  -- PROPAGATION
  relevances[gmodule.outnode.data] = R

  for i=1,#toposorted do
    local node = toposorted[i]
    local relevance = relevances[node]

    -- Propagate input relevance
    local input_relevance = relevance_propagate(node, relevance)

    if #node.mapindex == 1 then
      -- Case 1: Select node
      if node.selectindex then
        -- Initialize the selection table
        if relevances[node.mapindex[1]] == nil then
          relevances[node.mapindex[1]] = {}
        end

        if relevances[node.mapindex[1]][node.selectindex] == nil then
          relevances[node.mapindex[1]][node.selectindex] = input_relevance
        else
          relevances[node.mapindex[1]][node.selectindex]:add(input_relevance)
        end

      -- Case 2: Not select node
      else

        if relevances[node.mapindex[1]] == nil then
          relevances[node.mapindex[1]] = input_relevance
        else
          relevances[node.mapindex[1]]:add(input_relevance)
        end

      end

    else

      -- Case 3: Table uses information from several input nodes
      for j=1,#node.mapindex do
        if relevances[node.mapindex[j]] == nil then
          relevances[node.mapindex[j]] = input_relevance[j]
        else
          relevances[node.mapindex[j]]:add(input_relevance[j])
        end
      end

    end

  end

  return relevances[gmodule.innode.data]
end

function relevance_propagate(node, R)
  -- For nodes without modules (like select nodes),
  -- pass through
  if node.module == nil then return R end

  local I = node.input
  local module = node.module

  -- Unpack single-element inputs
  if #I == 1 then I = I[1] end

  -- MulTable: pass-through on non-gate inputs
  if torch.typename(module) == 'nn.CMulTable' then
    -- Identify the non-gate input node
    local input_nodes = node.mapindex
    local true_index = nil
    for i=1,#input_nodes do
      if torch.typename(input_nodes[i].module) ~= 'nn.Sigmoid' then
        true_index = i
        break
      end
    end

    return module:lrp(I, R, true_index)
  end

  if torch.typename(module) == 'nn.CAddTable' then
    return module:lrp(I, R)
  end

  if torch.typename(module) == 'nn.Linear' then
    return module:lrp(I, R)
  end

  if torch.typename(module) == 'nn.Reshape' then
    return module:lrp(I, R)
  end

  if torch.typename(module) == 'nn.SplitTable' then
    return module:lrp(I, R)
  end

  if torch.typename(module) == 'nn.LookupTable' then
    -- Batch mode, so sum over second (embedding) dimension
    return R:sum(2)
  end

  -- All other cases: pass-through
  return module:lrp(I, R)
end

function clearGrad(module) end
--[[
function clearGrad(module)
  -- Remove grad output and grad input
  -- to make space
  if module.gradOutput then
    module.gradOutput:resize(1)
  end
  if module.gradInput then
    if type(module.gradInput) == 'table' then
      for i=1,#module.gradInput do
        module.gradInput[i]:resize(1)
      end
    else
      module.gradInput:resize(1)
    end
  end
end
]]

function nn.Module:lrp(input, relevance)
  if self.initialized_lrp == nil then
    self.initialized_lrp = true

    self.Rin = self.gradInput --torch.CudaTensor()
  end

  self.Rin:resizeAs(relevance):copy(relevance)

  return self.Rin
end

function nn.Reshape:lrp(input, relevance)
  if self.initialized_lrp == nil then
    self.initialized_lrp = true

    self.Rin = self.gradInput --torch.CudaTensor()
  end

  self.Rin:resizeAs(input):copy(relevance:viewAs(input))

  return self.Rin
end

function nn.SplitTable:lrp(input, relevance)
  if self.initialized_lrp == nil then
    self.initialized_lrp = true

    self.Rin = self.gradInput --torch.CudaTensor()
  end

  local dimension = self:_getPositiveDimension(input)

  self.Rin:resizeAs(input)
  for i=1,#relevance do
    self.Rin:select(dimension, i):copy(relevance[i])
  end

  return self.Rin
end

-- MulTable, AddTable, Linear mirrored as closely as possible
-- from Arras's LRP_for_lstm
local eps = 0.001

function nn.CMulTable:lrp(input, relevance, true_index)
  if self.initialized_lrp == nil then
    self.initialized_lrp = true

    self.Rin = self.gradInput
  end

  for i=1,#input do
    self.Rin[i] = self.Rin[i] or input[i].new()
    if i == true_index then
      self.Rin[i]:resizeAs(relevance):copy(relevance)
    else
      self.Rin[i]:resizeAs(relevance):zero()
    end
  end

  return self.Rin
end

local denom = torch.CudaTensor()
local denom_sign = torch.CudaTensor()
local denom_sign_clone = torch.CudaTensor()

function nn.Linear:lrp(input, relevance, use_bias)
  -- Allocate memory we need for LRP here.
  if self.initialized_lrp == nil then
    self.initialized_lrp = true

    self.D = self.weight:size(2)
    self.M = self.weight:size(1)

    self.denom = denom --self.output --self.gradOutput --torch.CudaTensor()

    self.denom_sign = denom_sign --self.gradOutput --torch.CudaTensor()
    self.denom_sign_clone = denom_sign_clone --torch.CudaTensor()

    self.Rin = self.gradInput --torch.CudaTensor()
  end

  local b = relevance:size(1)

  -- Perform LRP propagation
  -- First, determine sign.
  self.denom:resizeAs(self.output):copy(self.output)

  self.denom_sign:resizeAs(self.output):copy(self.denom):sign()
  self.denom_sign_clone:resizeAs(self.output)
  self.denom_sign_clone:copy(self.denom_sign)
  self.denom_sign_clone:pow(2) -- pow(2) is faster than abs()
  self.denom_sign_clone:csub(1) -- This is now -1 at 0 and 0 everywhere else
  self.denom_sign:csub(self.denom_sign_clone) -- Fast in-place true sign

  -- Add epsilon to the denominator and invert
  self.denom:add(self.denom_sign:mul(eps)):cinv():cmul(relevance)

  -- Compute main 'messages'
  self.Rin:resizeAs(input):zero()
  self.Rin:addmm(0, self.Rin, 1, self.denom, self.weight)
  self.Rin:cmul(input)

  -- Add numerator stabilizer
  self.Rin:add(self.denom_sign:cmul(self.denom):sum(2):div(self.D):view(b, 1):expandAs(self.Rin))

  -- Add bias term if present and desired
  if use_bias and self.bias then
    self.Rin:add(self.denom:cmul(self.bias):sum(2):div(self.D):view(b, 1):expandAs(self.Rin))
  end

  -- Return
  return self.Rin
end

local sum_inputs = torch.CudaTensor()
local sign_sum = torch.CudaTensor()
local sign_sum_clone = torch.CudaTensor()

function nn.CAddTable:lrp(input, relevance)
  if self.initialized_lrp == nil then
    self.initialized_lrp = true

    self.sum_inputs = sum_inputs --self.output --torch.CudaTensor()
    self.sign_sum = sign_sum --self.gradOutput --torch.CudaTensor()
    self.sign_sum_clone = sign_sum_clone --torch.CudaTensor()

    self.results = self.gradInput
  end

  -- Get output and stabilize
  self.sum_inputs:resizeAs(self.output):copy(self.output)
  self.sign_sum:resizeAs(self.output):copy(self.sum_inputs):sign()
  self.sign_sum_clone:resizeAs(self.output):copy(self.sign_sum):abs():csub(1)
  self.sign_sum:csub(self.sign_sum_clone) -- Fast in-place true sign

  self.sum_inputs:add(self.sign_sum:mul(eps)):cinv()

  -- Scale relevance as input contributions
  for i=1,#input do
    self.results[i] = self.results[i] or input[1].new()
    self.results[i]:resizeAs(input[i]):copy(input[i]):cmul(self.sum_inputs):cmul(relevance)
  end

  -- Return
  for i=#input+1,#self.results do
    self.results[i] = nil
  end

  return self.results
end
