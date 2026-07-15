const ReplicatedStorage = game:GetService("ReplicatedStorage")
const DataSaveService = require(ReplicatedStorage.Services.DataSaveService)
local ProfileHandlerService = {}

const ProfileTemplate = require(ReplicatedStorage.Config.ProfileTemplate)

DataSaveService:SetTemplate(ProfileTemplate)
DataSaveService:SetProfileKeyTemplate("%s")
DataSaveService:CreateProfileStore()

return ProfileHandlerService