--love-icon-changer library by RamiLego4Game (Rami Sabbagh)
--[[
- Usage:
local lovePE = require("love-pe")

local icodata = lovePE.extractIcon(exeFile)

- Reference:
Version File Resource: https://msdn.microsoft.com/en-us/library/ms647001(v=vs.85).aspx
Icons:
https://msdn.microsoft.com/en-us/library/ms997538.aspx
]]

local bit = require("bit")
local utf8 = require("utf8")

local bor,band,lshift,rshift,tohex = bit.bor,bit.band,bit.lshift,bit.rshift,bit.tohex

local resourcesTypes = {
  "CURSOR",
  "BITMAP",
  "ICON",
  "MENU",
  "DIALOG",
  "STRING_TABLE",
  "FONT_DIRECTORY",
  "FONT",
  "ACCELERATORS",
  "UNFORMATTED_RESOURCE_DATA",
  "MESSAGE_TABLE",
  "GROUP_CURSOR",
  13,
  "GROUP_ICON",
  15,
  "VERSION_INFORMATION",
  17,18,19,20,21,22,23,
  "MANIFEST"
}
for k,v in ipairs(resourcesTypes) do
  resourcesTypes[v] = k
end

--==Internal Functions==--

local function decodeNumber(str,littleEndian)
  local num = 0
  
  if littleEndian then str = str:reverse() end
  
  for char in string.gmatch(str,".") do
    local byte = string.byte(char)
    
    num = lshift(num,8)
    num = bor(num, byte)
  end
  
  return num
end

local function encodeNumber(num,len,bigEndian)
  
  local chars = {}
  
  for i=1,len do
    chars[i] = string.char(band(num,255))
    num = rshift(num,8)
  end
  
  chars = table.concat(chars)
  
  if bigEndian then chars = chars:reverse() end
  
  return chars
end

local function decodeUTF16(str16)
  local giter = string.gmatch(str16,"..")
  local iter = function()
    local short = giter()
    if short then
      return decodeNumber(short,true)
    end
  end
  
  local nstr = {}
  
  local unicode = iter()
  
  while unicode do
    --Surrogate pairs
    if unicode >= 0xD800 and unicode <= 0xDBFF then
      local lowPair = iter()
      
      if lowPair and lowPair >= 0xDC00 and lowPair <= 0xDFFF then
        unicode = lshift(unicode-0xD800,10) + (lowPair-0xDC00) + 0x01000
        nstr[#nstr+1] = utf8.char(unicode)
        unicode = iter()
      else --Unpaired surrogate
        nstr[#nstr+1] = utf8.char(unicode)
        unicode = lowPair
      end
    else
      nstr[#nstr+1] = utf8.char(unicode)
      unicode = iter()
    end
  end
  
  return table.concat(nstr)
end

local function encodeUTF16(str8)
  
  local nstr ={}
  
  for pos, unicode in utf8.codes(str8) do
    if unicode >= 0x10000 then --Encode as surrogate pair
      unicode = unicode - 0x01000
      nstr[#nstr+1] = encodeNumber(rshift(unicode,10)+0xD800,2,false)
      nstr[#nstr+1] = encodeNumber(band(unicode,0x3FF)+0xDC00,2,false)
    else
      nstr[#nstr+1] = encodeNumber(unicode,2,false)
    end
  end
  
  return table.concat(nstr)
end

local function convertRVA2Offset(RVA,Sections)
  for id, Section in ipairs(Sections) do
    if (Section.VirtualAddress <= RVA) and (RVA < (Section.VirtualAddress + Section.VirtualSize)) then
      return Section.PointerToRawData + (RVA - Section.VirtualAddress)
    end
  end
  error("FAILED "..tohex(RVA))
end

local function readResourceDirectoryTable(exeFile,Sections,RootOffset,Level)
  local Tree = {}
  
  local Characteristics = decodeNumber(exeFile:read(4),true)
  local TimeDateStamp = decodeNumber(exeFile:read(4),true)
  local MajorVersion = decodeNumber(exeFile:read(2),true)
  local MinorVersion = decodeNumber(exeFile:read(2),true)
  local NumberOfNameEntries = decodeNumber(exeFile:read(2),true)
  local NumberOfIDEntries = decodeNumber(exeFile:read(2),true)
  
  --Parse Entries
  for i=1,NumberOfNameEntries+NumberOfIDEntries do
    local Name = decodeNumber(exeFile:read(4),true)
    local Offset = decodeNumber(exeFile:read(4),true)
    
    local ReturnOffset = exeFile:tell()
    
    --Parse name/id for entry
    if band(Name,0x80000000) ~= 0 then
      --Name is a string RVA
      local NameOffset = convertRVA2Offset(band(Name,0x7FFFFFFF), Sections)
      
      exeFile:seek(NameOffset)
      
      local NameLength = decodeNumber(exeFile:read(2),true)
      --Decode UTF-16LE string
      Name = decodeUTF16(exeFile:read(NameLength*2))
    else
      --Name is an ID
      Name = band(Name,0xFFFF)
      
      if Level == 0 then
        if resourcesTypes[Name] then
          Name = resourcesTypes[Name]
        end
      end
    end
    
    if band(Offset,0x80000000) ~= 0 then
      --Another directory
      exeFile:seek(RootOffset + band(Offset,0x7FFFFFFF))
      
      Tree[Name] = readResourceDirectoryTable(exeFile,Sections,RootOffset,Level+1)
    else
      --Data offset
      exeFile:seek(RootOffset + band(Offset,0x7FFFFFFF))
      
      local DataRVA = decodeNumber(exeFile:read(4),true)
      local DataSize = decodeNumber(exeFile:read(4),true)
      local DataCodepage = decodeNumber(exeFile:read(4),true)
      
      local DataOffset = convertRVA2Offset(DataRVA,Sections)
      
      exeFile:seek(DataOffset)
      
      Tree[Name] = exeFile:read(DataSize)
    end
    
    exeFile:seek(ReturnOffset)
  end
  
  return Tree
end

local function buildResourcesDirectoryTable(ResourcesTree,VirtualAddress)
  local Data = {}
  local Offset = 0
  local Level = 0
  
  local function writeDirectory(Directory)
    local NameEntries, IDEntries = {}, {}
    
    Level = Level + 1
    
    for k,v in pairs(Directory) do
      if type(k) == "string" then
        if Level == 1 and resourcesTypes[k] then
          IDEntries[#IDEntries+1] = {resourcesTypes[k],v}
        else
          NameEntries[#NameEntries+1] = {k,v}
        end
      elseif type(k) == "number" then
        IDEntries[#IDEntries+1] = {k,v}
      end
    end
    
    --Write the resource directory table
    Data[#Data+1] = encodeNumber(0,4,false) Offset = Offset + 4 --Characteristics
    Data[#Data+1] = encodeNumber(os.time(),4,false) Offset = Offset + 4 --Time/Date Stamp
    Data[#Data+1] = encodeNumber(1,2,false) Offset = Offset + 2 --Major Version
    Data[#Data+1] = encodeNumber(0,2,false) Offset = Offset + 2 --Minor Version
    Data[#Data+1] = encodeNumber(#NameEntries,2,false) Offset = Offset + 2 --Number of name entries
    Data[#Data+1] = encodeNumber(#IDEntries,2,false) Offset = Offset + 2 --Number of ID entries
    
    local EntriesID = #Data --Where the entries data start
    
    --Pre-Allocate the place for the entries
    for i=1,#NameEntries+#IDEntries do
      Data[#Data+1] = ""
      Data[#Data+1] = ""
      Offset = Offset + 8
    end
    
    for _, Entry in ipairs(NameEntries) do
      --Write resource directory string
      local StringRVA = VirtualAddress+Offset
      local String = encodeUTF16(Entry[1])
      
      Data[#Data+1] = encodeNumber(#String/2,2,false) Offset = Offset + 2 --String Length
      Data[#Data+1] = String; Offset = Offset + #String --Unicode String
      
      Entry[3] = StringRVA + 0x80000000 --A string name
      Entry[4] = Offset
      
      if type(Entry[2]) == "table" then --Sub-directory
        Entry[4] = Entry[4] + 0x80000000 --Set sub-directory flag
        writeDirectory(Entry[2])
      else --Data
        Data[#Data+1] = encodeNumber(VirtualAddress+Offset+16,4,false) Offset = Offset + 4 --Predict the DataRVA
        Data[#Data+1] = encodeNumber(#Entry[2],4,false) Offset = Offset + 4 --Size
        Data[#Data+1] = encodeNumber(0,4,false) Offset = Offset + 4 --Codepoint
        Data[#Data+1] = encodeNumber(0,4,false) Offset = Offset + 4 --Reserved
        Data[#Data+1] = Entry[2]; Offset = Offset + #Entry[2] --The actual data
      end
    end
    
    for _, Entry in ipairs(IDEntries) do
      Entry[3] = Entry[1] --The entry id itself
      Entry[4] = Offset
      
      if type(Entry[2]) == "table" then --Sub-directory
        Entry[4] = Entry[4] + 0x80000000 --Set sub-directory flag
        writeDirectory(Entry[2])
      else --Data
        Data[#Data+1] = encodeNumber(VirtualAddress+Offset+16,4,false) Offset = Offset + 4 --Predict the DataRVA
        Data[#Data+1] = encodeNumber(#Entry[2],4,false) Offset = Offset + 4 --Size
        Data[#Data+1] = encodeNumber(0,4,false) Offset = Offset + 4 --Codepoint
        Data[#Data+1] = encodeNumber(0,4,false) Offset = Offset + 4 --Reserved
        Data[#Data+1] = Entry[2]; Offset = Offset + #Entry[2] --The actual data
      end
    end
    
    for _, Entry in ipairs(NameEntries) do
      Data[EntriesID+1] = Entry[3]; EntriesID = EntriesID + 1
      Data[EntriesID+1] = Entry[4]; EntriesID = EntriesID + 1
    end
    
    for _, Entry in ipairs(IDEntries) do
      Data[EntriesID+1] = Entry[3]; EntriesID = EntriesID + 1
      Data[EntriesID+1] = Entry[4]; EntriesID = EntriesID + 1
    end
    
    Level = Level - 1
    
  end
  
  writeDirectory(ResourcesTree)
  
  return table.concat(Data)
end

local function getAnyKey(t)
  for k,v in pairs(t) do
    return k
  end
end


local function getAnyValue(t)
  for k,v in pairs(t) do
    return v
  end
end

local function extractGroupIcon(ResourcesTree,GroupID)
  --Icon extraction process
  local IconGroup = getAnyValue(ResourcesTree["GROUP_ICON"][GroupID])
  
  local Icons = {""}
  
  local o = 5 --String Offset
  
  --Read the icon header
  local Count = decodeNumber(IconGroup:sub(o,o+1),true)
  
  o = o+2
  
  local DataOffset = 6 + 16*Count
  
  for i=1,Count do
    o = o+12
    
    local IcoID = decodeNumber(IconGroup:sub(o,o+1),true)
    
    Icons[#Icons+1] = getAnyValue(ResourcesTree["ICON"][IcoID])
    
    local Length = #Icons[#Icons]
    
    IconGroup = IconGroup:sub(1,o-1) .. encodeNumber(DataOffset,4,false) .. IconGroup:sub(o+2,-1)
    
    o = o + 4
    
    DataOffset = DataOffset + Length
  end
  
  Icons[1] = IconGroup
  
  return table.concat(Icons)
end

local function removeGroupIcon(ResourcesTree,GroupID)
  local IconGroup = getAnyValue(ResourcesTree["GROUP_ICON"][GroupID])
  ResourcesTree["GROUP_ICON"][GroupID] = nil --Delete the group icon
  
  local o = 5 --String Offset
  
  --Read the icon header
  local Count = decodeNumber(IconGroup:sub(o,o+1),true)
  
  o = o+2
  
  for i=1,Count do
    o = o+12
    
    local IcoID = decodeNumber(IconGroup:sub(o,o+1),true)
    
    ResourcesTree["ICON"][IcoID] = nil
    
    o = o + 2
  end
end

local function addGroupIcon(ResourcesTree,GroupID,icoFile)
  local IconGroup = {}
  local Icons = {}
  local NextIconID = 1
  
  IconGroup[#IconGroup+1] = icoFile:read(4)
  
  local Count = decodeNumber(icoFile:read(2),true)
  
  IconGroup[#IconGroup+1] = encodeNumber(Count,2,false)
  
  for i=1,Count do
    IconGroup[#IconGroup+1] = icoFile:read(8)
    
    local IcoSize = decodeNumber(icoFile:read(4),true)
    local IcoOffset = decodeNumber(icoFile:read(4),true)
    
    IconGroup[#IconGroup+1] = encodeNumber(IcoSize,4,false)
    
    --Find an empty slot for the icon data
    while ResourcesTree["ICON"][NextIconID] do
      NextIconID = NextIconID + 1
    end
    
    IconGroup[#IconGroup+1] = encodeNumber(NextIconID,2,false)
    
    local ReturnOffset = icoFile:tell()
    
    icoFile:seek(IcoOffset)
    
    ResourcesTree["ICON"][NextIconID] = {[1033] = icoFile:read(IcoSize)}
    
    icoFile:seek(ReturnOffset)
    
    NextIconID = NextIconID + 1
  end
  
  icoFile:seek(0)
  
  IconGroup = table.concat(IconGroup)
  
  ResourcesTree["GROUP_ICON"][GroupID] = {[1033] = IconGroup}
end

local function skipDOSHeader(exeFile)
  if exeFile:read(2) ~= "MZ" then error("This is not an executable file !",3) end
  
  exeFile:read(58) --Skip 58 bytes
  
  local PEHeaderOffset = decodeNumber(exeFile:read(4),true) --Offset to the 'PE\0\0' signature relative to the beginning of the file
  
  exeFile:seek(PEHeaderOffset) --Seek into the PE Header
end

local function skipPEHeader(exeFile)
  if exeFile:read(4) ~= "PE\0\0" then error("Corrupted executable file !",3) end
end

local function parseCOFFHeader(exeFile)
  --Corrently only parses the NumberOfSections value, and skips the rest.
  local values = {}
  
  exeFile:read(2) --Skip Machine.
  
  values.NumberOfSections = decodeNumber(exeFile:read(2),true)
  
  exeFile:read(16) --Skip 3 long values (12 bytes) and 2 short values (4 bytes).
  
  return values
end

local function parsePEOptHeader(exeFile)
  local values = {}
  
  local PEOptionalHeaderSignature = decodeNumber(exeFile:read(2),true)
  
  values.x86, values.x64 = false, false --Executable arch
  
  if PEOptionalHeaderSignature == 267 then --It's x86
    values.x86 = true
  elseif PEOptionalHeaderSignature == 523 then --It's x64
    values.x64 = true
  else
    error("ROM images are not supported !",3)
  end
  
  exeFile:read(values.x64 and 106 or 90) --Skip 106 bytes for x64, and 90 bytes for x86
  
  values.NumberOfRvaAndSizes = decodeNumber(exeFile:read(4),true)
  
  return values
end

local function parseDataTables(exeFile,NumberOfRvaAndSizes)
  local DataDirectories = {}
  
  for i=1, NumberOfRvaAndSizes do
    DataDirectories[i] = {decodeNumber(exeFile:read(4),true), decodeNumber(exeFile:read(4),true)}
    print("DataDirectory #"..i,DataDirectories[i][1],DataDirectories[i][2])
  end
  
  return DataDirectories
end

local function writeDataDirectories(exeFile, DataDirectories)
  for i, Directory in ipairs(DataDirectories) do
    exeFile:write(encodeNumber(Directory[1],4,false))
    exeFile:write(encodeNumber(Directory[2],4,false))
  end
end

local function parseSectionsTable(exeFile,NumberOfSections)
  local Sections = {}
  
  for i=1, NumberOfSections do
    print("\n------=Section=------",i)
    
    local Section = {}
    
    Section.Name = ""
    for i=1,8 do
      local char = exeFile:read(1)
      if char ~= "\0" then
        Section.Name = Section.Name .. char
      end
    end
    
    Section.VirtualSize = decodeNumber(exeFile:read(4),true)
    Section.VirtualAddress = decodeNumber(exeFile:read(4),true)
    Section.SizeOfRawData = decodeNumber(exeFile:read(4),true)
    Section.PointerToRawData = decodeNumber(exeFile:read(4),true)
    Section.PointerToRelocations = decodeNumber(exeFile:read(4),true)
    Section.PointerToLinenumbers = decodeNumber(exeFile:read(4),true)
    Section.NumberOfRelocations = decodeNumber(exeFile:read(2),true)
    Section.NumberOfLinenumbers = decodeNumber(exeFile:read(2),true)
    Section.Characteristics = decodeNumber(exeFile:read(4),true)
    
    for k,v in pairs(Section) do
      print(k,v)
    end
    
    Sections[i] = Section
  end
  
  return Sections
end

local function writeSectionsTable(exeFile,Sections)
  for id, Section in ipairs(Sections) do
    exeFile:write(Section.Name.."\0")
    exeFile:write(encodeNumber(Section.VirtualSize,4,true))
    exeFile:write(encodeNumber(Section.VirtualAddress,4,true))
    exeFile:write(encodeNumber(Section.SizeOfRawData,4,true))
    exeFile:write(encodeNumber(Section.PointerToRawData,4,true))
    exeFile:write(encodeNumber(Section.PointerToRelocations,4,true))
    exeFile:write(encodeNumber(Section.PointerToLinenumbers,4,true))
    exeFile:write(encodeNumber(Section.NumberOfRelocations,2,true))
    exeFile:write(encodeNumber(Section.NumberOfLinenumbers,2,true))
    exeFile:write(encodeNumber(Section.Characteristics,4,true))
  end
end

local function readSections(exeFile,Sections)
  local SectionsData = {}
  
  for id, Section in ipairs(Sections) do
    exeFile:seek(Section.PointerToRawData)
    SectionsData[id] = exeFile:read(Section.SizeOfRawData)
  end
  
  return SectionsData
end

local function writeSections(exeFile,Sections,SectionsData)
  for id, Section in ipairs(Sections) do
    exeFile:seek(Section.PointerToRawData)
    exeFile:write(SectionsData[id])
  end
end

local function readTrailData(exeFile)
  
  local currentPos = exeFile:tell()
  local size = exeFile:getSize()
  
  return exeFile:read(size-currentPos+1)
  
end

local function writeTree(tree,path)
  for k,v in pairs(tree) do
    if type(v) == "table" then
      love.filesystem.createDirectory(path..k)
      writeTree(v,path..k.."/")
    else
      love.filesystem.write(path..k,v)
    end
  end
end

--==User API==--

local icapi = {}

function icapi.extractIcon(exeFile)
  
  --DOS Header
  skipDOSHeader(exeFile)
  
  --PE Header
  skipPEHeader(exeFile)
  
  --COFF Header
  local NumberOfSections = parseCOFFHeader(exeFile).NumberOfSections
  
  --PE Optional Header
  local NumberOfRvaAndSizes = parsePEOptHeader(exeFile).NumberOfRvaAndSizes
  
  local DataDirectories = parseDataTables(exeFile,NumberOfRvaAndSizes)
  
  --Sections Table
  local Sections = parseSectionsTable(exeFile,NumberOfSections)
  
  --Calculate the file offset to the resources data directory
  local ResourcesOffset = convertRVA2Offset(DataDirectories[3][1],Sections)
  
  --Seek into the resources data !
  exeFile:seek(ResourcesOffset)
  
  local ResourcesTree = readResourceDirectoryTable(exeFile,Sections,ResourcesOffset,0)
  
  local IconKeys,FirstIcon = {}
  
  for k,v in pairs(ResourcesTree["GROUP_ICON"]) do
    IconKeys[#IconKeys+1] = k
    ResourcesTree["GROUP_ICON"][k] = extractGroupIcon(ResourcesTree,k)
    if not FirstIcon then FirstIcon = ResourcesTree["GROUP_ICON"][k] end
  end
  
  for k,v in pairs(IconKeys) do
    ResourcesTree["GROUP_ICON"][v..".ico"] = ResourcesTree["GROUP_ICON"][v]
    ResourcesTree["GROUP_ICON"][v] = nil
  end
  
  writeTree(ResourcesTree,"/")
  
  return FirstIcon
  
end

function icapi.replaceIcon(exeFile,icoFile,newFile)
  
  --DOS Header
  skipDOSHeader(exeFile)
  
  --PE Header
  skipPEHeader(exeFile)
  
  --COFF Header
  local NumberOfSections = parseCOFFHeader(exeFile).NumberOfSections
  
  --PE Optional Header
  local NumberOfRvaAndSizes = parsePEOptHeader(exeFile).NumberOfRvaAndSizes
  
  local DataDirectoriesOffset = exeFile:tell() --Where the DataDirectories are stored
  
  local DataDirectories = parseDataTables(exeFile,NumberOfRvaAndSizes)
  
  --Sections Table
  local SectionsOffset = exeFile:tell() --Where the sections tables start
  
  local Sections = parseSectionsTable(exeFile,NumberOfSections)
  
  local SectionsData = readSections(exeFile,Sections)
  
  --Trail data
  local TrailData = readTrailData(exeFile)
  
  --Calculate the file offset to the resources data directory
  local ResourcesOffset = convertRVA2Offset(DataDirectories[3][1],Sections)
  
  --Seek into the resources data !
  exeFile:seek(ResourcesOffset)
  
  --Parse the resources data
  local ResourcesTree = readResourceDirectoryTable(exeFile,Sections,ResourcesOffset,0)
  
  print("Finished reading...")
  
  local GroupID = getAnyKey(ResourcesTree["GROUP_ICON"])
  
  removeGroupIcon(ResourcesTree,GroupID) print("Removed Icon...")
  addGroupIcon(ResourcesTree,GroupID,icoFile) print("Added new Icon...")
  
  local RSRC_ID = 0
  
  for k,Section in ipairs(Sections) do
    if Section.Name == ".rsrc" then
      RSRC_ID = k
      break
    end
  end
  
  print("Rebuilding resources section...")
  
  SectionsData[RSRC_ID] = buildResourcesDirectoryTable(ResourcesTree,Sections[RSRC_ID].VirtualAddress)
  
  print("Patching data tables...")
  
  local NewRSRCSize = #SectionsData[RSRC_ID]
  local OldRSRCSize = DataDirectories[3][2]
  local ShiftOffset = NewRSRCSize - OldRSRCSize
  
  print("NEW OLD OFFSET",NewRSRCSize,OldRSRCSize,ShiftOffset)
  
  DataDirectories[3][2] = NewRSRCSize
  Sections[RSRC_ID].VirtualSize = Sections[RSRC_ID].VirtualSize + ShiftOffset
  Sections[RSRC_ID].SizeOfRawData = Sections[RSRC_ID].SizeOfRawData + ShiftOffset
  
  local RSRC_Pointer = Sections[RSRC_ID].PointerToRawData
  
  for id, Section in ipairs(Sections) do
    if Sections[id].PointerToRawData > RSRC_Pointer then
      Sections[id].PointerToRawData = Sections[id].PointerToRawData + ShiftOffset
    end
    if Sections[id].PointerToRelocations > RSRC_Pointer then
      Sections[id].PointerToRelocations = Sections[id].PointerToRelocations + ShiftOffset
    end
    if Sections[id].PointerToLinenumbers > RSRC_Pointer then
      Sections[id].PointerToLinenumbers = Sections[id].PointerToLinenumbers + ShiftOffset
    end
  end
  
  print("Writing the DOS,PE,COFF and PEOpt headers...",DataDirectoriesOffset)
  
  --Copy the DOS,PE,COFF and PEOpt headers
  exeFile:seek(0)
  newFile:write(exeFile:read(DataDirectoriesOffset))
  
  print("Writing data directories...") writeDataDirectories(newFile,DataDirectories)
  print("Writing sections table...") writeSectionsTable(newFile,Sections)
  print("Writing sections data...") writeSections(newFile,Sections,SectionsData)
  print("Writing trail data...") newFile:write(TrailData)
  print("Done")
  
  return true
end

return icapi